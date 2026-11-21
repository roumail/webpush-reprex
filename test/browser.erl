%% Plays the BROWSER on the phone (the installed web app's service worker).
%%
%% new_subscription/1 does what pushManager.subscribe() does: makes a P-256
%% key pair and a 16-byte auth secret, and returns
%%   - the subscription JSON the web app would send to the relay, and
%%   - the private half the browser keeps.
%% decrypt/2 does what the browser does when a push arrives (RFC 8291 +
%% RFC 8188 aes128gcm, single record). It is written independently of
%% src/webpush.erl so the test doesn't check the code against itself.
-module(browser).
-export([new_subscription/1, decrypt/2, b64/1, unb64/1]).

new_subscription(Endpoint) ->
    {UaPublic, UaPrivate} = crypto:generate_key(ecdh, prime256v1),
    Auth = crypto:strong_rand_bytes(16),
    Json = #{<<"endpoint">> => Endpoint,
             <<"expirationTime">> => null,
             <<"keys">> => #{<<"p256dh">> => b64(UaPublic), <<"auth">> => b64(Auth)}},
    Secret = #{ua_public => UaPublic, ua_private => UaPrivate, auth => Auth},
    {Json, Secret}.

decrypt(<<Salt:16/binary, _RecordSize:32, IdLen:8, AsPublic:IdLen/binary, Ciphertext/binary>>,
        #{ua_public := UaPublic, ua_private := UaPrivate, auth := Auth}) ->
    Ecdh = crypto:compute_key(ecdh, AsPublic, UaPrivate, prime256v1),
    PrkKey = hmac(Auth, Ecdh),
    Ikm = hmac(PrkKey, <<"WebPush: info", 0, UaPublic/binary, AsPublic/binary, 1>>),
    Prk = hmac(Salt, Ikm),
    <<Cek:16/binary, _/binary>> = hmac(Prk, <<"Content-Encoding: aes128gcm", 0, 1>>),
    <<Nonce:12/binary, _/binary>> = hmac(Prk, <<"Content-Encoding: nonce", 0, 1>>),
    CtLen = byte_size(Ciphertext) - 16,
    <<Ct:CtLen/binary, Tag:16/binary>> = Ciphertext,
    case crypto:crypto_one_time_aead(aes_128_gcm, Cek, Nonce, Ct, <<>>, Tag, false) of
        error -> {error, cannot_decrypt};
        Padded -> unpad(Padded)
    end;
decrypt(_, _) ->
    {error, bad_header}.

%% The last record ends with 0x02, then optional zero padding.
unpad(Padded) ->
    case string:trim(Padded, trailing, [0]) of
        <<>> -> {error, no_delimiter};
        Trimmed ->
            Len = byte_size(Trimmed) - 1,
            case Trimmed of
                <<Plain:Len/binary, 2>> -> {ok, Plain};
                _ -> {error, no_delimiter}
            end
    end.

hmac(Key, Data) -> crypto:mac(hmac, sha256, Key, Data).

b64(Bin) -> base64:encode(Bin, #{mode => urlsafe, padding => false}).
unb64(Text) -> base64:decode(Text, #{mode => urlsafe, padding => false}).
