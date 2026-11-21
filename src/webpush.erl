%% Sends one Web Push message, the way the relay will.
%%
%%   RFC 8030  Generic Event Delivery Using HTTP Push   (the POST, TTL, Urgency)
%%   RFC 8291  Message Encryption for Web Push          (aes128gcm to the phone's keys)
%%   RFC 8292  VAPID                                    (the relay signs its requests)
%%
%% Usage:
%%   {ok, Sub} = webpush:subscription(JsonFromTheWebApp),
%%   Vapid     = webpush:vapid_keys(<<"https://family.example">>),  % keep these
%%   ok        = webpush:send(Sub, <<"New message">>, Vapid, #{urgency => high}).
-module(webpush).
-export([subscription/1, vapid_keys/1, encrypt/2, encrypt/3, send/4]).

-export_type([subscription/0, vapid/0]).

-type subscription() :: #{endpoint := binary(), p256dh := binary(), auth := binary()}.
-type vapid() :: #{public := binary(), private := binary(), subject := binary()}.

%% One aes128gcm record of 4096 bytes: minus the 86-byte header, the 16-byte
%% tag and the 1-byte delimiter (RFC 8291 §4).
-define(RECORD_SIZE, 4096).
-define(MAX_PAYLOAD, 3993).
-define(JWT_LIFETIME, 12 * 3600).   % must be at most 24 h (RFC 8292 §2)

%% ---------------------------------------------------------------------------
%% The subscription the web app sends: PushSubscription.toJSON(), decoded.

-spec subscription(map()) -> {ok, subscription()} | {error, invalid_subscription}.
subscription(#{<<"endpoint">> := Endpoint,
               <<"keys">> := #{<<"p256dh">> := P256dh, <<"auth">> := Auth}})
  when is_binary(Endpoint), is_binary(P256dh), is_binary(Auth) ->
    try {unb64(P256dh), unb64(Auth)} of
        %% An uncompressed P-256 point (0x04, X, Y) and a 16-byte secret.
        {<<4, _:64/binary>> = Key, <<_:16/binary>> = Secret} ->
            {ok, #{endpoint => Endpoint, p256dh => Key, auth => Secret}};
        _ ->
            {error, invalid_subscription}
    catch
        error:_ -> {error, invalid_subscription}
    end;
subscription(_) ->
    {error, invalid_subscription}.

%% ---------------------------------------------------------------------------
%% VAPID: the relay's own P-256 key pair. Generate once, keep it; the web
%% app passes the public key to pushManager.subscribe() as
%% applicationServerKey. Subject: a mailto: or https: contact URL.

-spec vapid_keys(binary()) -> vapid().
vapid_keys(Subject) ->
    {Public, Private} = crypto:generate_key(ecdh, prime256v1),
    #{public => Public, private => Private, subject => Subject}.

%% ---------------------------------------------------------------------------
%% Encryption (RFC 8291). encrypt/3 takes a fixed salt and server key, for
%% the RFC's test vector only; real pushes always use encrypt/2.

-spec encrypt(binary(), subscription()) -> binary().
encrypt(Payload, Sub) ->
    encrypt(Payload, Sub, #{}).

-spec encrypt(binary(), subscription(), #{salt => binary(), as_private => binary()}) -> binary().
encrypt(Payload, #{p256dh := UaPublic, auth := Auth}, Opts) ->
    Salt = maps:get(salt, Opts, crypto:strong_rand_bytes(16)),
    %% A fresh "application server" key pair per message.
    {AsPublic, AsPrivate} = case Opts of
        #{as_private := Fixed} -> crypto:generate_key(ecdh, prime256v1, Fixed);
        _ -> crypto:generate_key(ecdh, prime256v1)
    end,
    EcdhSecret = crypto:compute_key(ecdh, UaPublic, AsPrivate, prime256v1),
    %% Mix in the phone's auth secret, then derive the key and nonce (HKDF).
    PrkKey = hmac(Auth, EcdhSecret),
    Ikm = hmac(PrkKey, <<"WebPush: info", 0, UaPublic/binary, AsPublic/binary, 1>>),
    Prk = hmac(Salt, Ikm),
    <<Cek:16/binary, _/binary>> = hmac(Prk, <<"Content-Encoding: aes128gcm", 0, 1>>),
    <<Nonce:12/binary, _/binary>> = hmac(Prk, <<"Content-Encoding: nonce", 0, 1>>),
    %% One record: the payload, then 0x02 ("last record"), no padding.
    {Ciphertext, Tag} = crypto:crypto_one_time_aead(aes_128_gcm, Cek, Nonce,
                                                    <<Payload/binary, 2>>, <<>>, true),
    %% Header: salt, record size, key id length, key id (the server key).
    <<Salt/binary, ?RECORD_SIZE:32, (byte_size(AsPublic)):8, AsPublic/binary,
      Ciphertext/binary, Tag/binary>>.

%% ---------------------------------------------------------------------------
%% Sending (RFC 8030 + 8292).
%% Opts: ttl (seconds the push service keeps it, default 1 day),
%%       urgency (very_low | low | normal | high, default normal).

-spec send(subscription(), binary(), vapid(), map()) ->
    ok | {error, gone | payload_too_large | {http, integer(), binary()} | term()}.
send(_Sub, Payload, _Vapid, _Opts) when byte_size(Payload) > ?MAX_PAYLOAD ->
    {error, payload_too_large};
send(#{endpoint := Endpoint} = Sub, Payload, Vapid, Opts) ->
    Headers = [{"ttl", integer_to_list(maps:get(ttl, Opts, 86400))},
               {"urgency", atom_to_list(maps:get(urgency, Opts, normal))},
               {"content-encoding", "aes128gcm"},
               {"authorization", binary_to_list(authorization(Endpoint, Vapid))}],
    Request = {binary_to_list(Endpoint), Headers, "application/octet-stream",
               encrypt(Payload, Sub)},
    case httpc:request(post, Request, http_options(Endpoint), [{body_format, binary}]) of
        {ok, {{_, Code, _}, _, _}} when Code >= 200, Code < 300 -> ok;
        %% The phone unsubscribed or the app was removed: delete it.
        {ok, {{_, Code, _}, _, _}} when Code =:= 404; Code =:= 410 -> {error, gone};
        {ok, {{_, Code, _}, _, Body}} -> {error, {http, Code, Body}};
        {error, Reason} -> {error, Reason}
    end.

%% "vapid t=<JWT>, k=<public key>"; the JWT is ES256-signed and names the
%% push service's origin as its audience.
authorization(Endpoint, #{public := Public, private := Private, subject := Subject}) ->
    Header = b64(iolist_to_binary(json:encode(#{<<"typ">> => <<"JWT">>, <<"alg">> => <<"ES256">>}))),
    Claims = b64(iolist_to_binary(json:encode(
        #{<<"aud">> => origin(Endpoint),
          <<"exp">> => erlang:system_time(second) + ?JWT_LIFETIME,
          <<"sub">> => Subject}))),
    SigningInput = <<Header/binary, ".", Claims/binary>>,
    %% crypto signs in DER; a JWT wants the raw 32-byte r and s.
    Der = crypto:sign(ecdsa, sha256, SigningInput, [Private, prime256v1]),
    {'ECDSA-Sig-Value', R, S} = public_key:der_decode('ECDSA-Sig-Value', Der),
    Jwt = <<SigningInput/binary, ".", (b64(<<R:256, S:256>>))/binary>>,
    <<"vapid t=", Jwt/binary, ", k=", (b64(Public))/binary>>.

%% scheme://host[:port]
origin(Endpoint) ->
    case uri_string:parse(Endpoint) of
        #{scheme := Scheme, host := Host, port := Port} ->
            <<Scheme/binary, "://", Host/binary, ":", (integer_to_binary(Port))/binary>>;
        #{scheme := Scheme, host := Host} ->
            <<Scheme/binary, "://", Host/binary>>
    end.

%% Real push services are HTTPS: verify their certificate and host name.
http_options(<<"https:", _/binary>>) ->
    [{timeout, 10000},
     {ssl, [{verify, verify_peer},
            {cacerts, public_key:cacerts_get()},
            {customize_hostname_check,
             [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]}];
http_options(_) ->
    [{timeout, 10000}].

hmac(Key, Data) -> crypto:mac(hmac, sha256, Key, Data).

b64(Bin) -> base64:encode(Bin, #{mode => urlsafe, padding => false}).
unb64(Text) -> base64:decode(Text, #{mode => urlsafe, padding => false}).
