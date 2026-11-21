%% Feature: the relay sends a Web Push message to an installed web app.
%%
%% Cast (see README.md):
%%   webpush             - the code under test: what the relay will do
%%   browser             - plays the phone's browser (subscribes, decrypts)
%%   fake_push_service   - plays Apple's / Google's push server
%%
%% One test case per scenario; Given/When/Then are step/2 labels, which
%% show in the Common Test log (_build/test/logs/index.html).
-module(webpush_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([encrypts_the_rfc8291_example/1,
         browser_helper_reads_the_rfc8291_example/1,
         delivers_a_message_the_browser_can_read/1,
         signs_the_request_with_vapid/1,
         asks_for_ttl_and_urgency/1,
         every_push_is_encrypted_afresh/1,
         a_gone_subscription_is_reported/1,
         the_largest_payload_fits_and_one_more_byte_is_refused/1,
         reads_the_subscription_json_from_the_web_app/1]).

all() ->
    [encrypts_the_rfc8291_example,
     browser_helper_reads_the_rfc8291_example,
     delivers_a_message_the_browser_can_read,
     signs_the_request_with_vapid,
     asks_for_ttl_and_urgency,
     every_push_is_encrypted_afresh,
     a_gone_subscription_is_reported,
     the_largest_payload_fits_and_one_more_byte_is_refused,
     reads_the_subscription_json_from_the_web_app].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(webpush),
    Config.

end_per_suite(_Config) ->
    ok.

-define(SUBJECT, <<"https://family.example">>).

%% ---------------------------------------------------------------------------
%% RFC 8291, Appendix A: fixed keys and salt give a known result. This pins
%% the encryption to the standard, byte for byte.

rfc() ->
    U = fun browser:unb64/1,
    #{plaintext   => U(<<"V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24">>),
      as_private  => U(<<"yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw">>),
      ua_public   => U(<<"BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4">>),
      ua_private  => U(<<"q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94">>),
      salt        => U(<<"DGv6ra1nlYgDCS1FRnbzlw">>),
      auth        => U(<<"BTBZMqHH6r4Tts7J_aSIgg">>),
      header      => U(<<"DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8">>),
      ciphertext  => U(<<"8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEsbI_0LpXMuGvnzQ">>)}.

encrypts_the_rfc8291_example(_Config) ->
    #{plaintext := Plain, ua_public := UaPub, auth := Auth, salt := Salt,
      as_private := AsPriv, header := Header, ciphertext := Ct} = rfc(),
    Sub = #{endpoint => <<"https://push.example/x">>, p256dh => UaPub, auth => Auth},
    step("Given the RFC's subscription keys, salt and server key", fun() -> ok end),
    Body = step("When the relay encrypts the RFC's message", fun() ->
        webpush:encrypt(Plain, Sub, #{salt => Salt, as_private => AsPriv})
    end),
    step("Then the body is the RFC's header followed by its ciphertext", fun() ->
        ?assertEqual(<<Header/binary, Ct/binary>>, Body)
    end).

browser_helper_reads_the_rfc8291_example(_Config) ->
    %% Tests the tester: the fake browser must decrypt the RFC's own message.
    #{plaintext := Plain, ua_public := UaPub, ua_private := UaPriv, auth := Auth,
      header := Header, ciphertext := Ct} = rfc(),
    Secret = #{ua_public => UaPub, ua_private => UaPriv, auth => Auth},
    step("When the browser helper decrypts the RFC's message", fun() -> ok end),
    step("Then it reads the RFC's plaintext", fun() ->
        ?assertEqual({ok, Plain}, browser:decrypt(<<Header/binary, Ct/binary>>, Secret))
    end).

%% ---------------------------------------------------------------------------
%% End to end through a fake push service.

delivers_a_message_the_browser_can_read(_Config) ->
    {Sub, Secret, Vapid} = step("Given a phone subscribed through the push service", fun() ->
        subscribed(201)
    end),
    Result = step("When the relay pushes \"Dad: dinner is ready\"", fun() ->
        webpush:send(Sub, <<"Dad: dinner is ready">>, Vapid, #{})
    end),
    #{method := Method, path := Path, headers := Headers, body := Body} = received(),
    step("Then the push service accepted a POST to the subscription's endpoint", fun() ->
        ?assertEqual(ok, Result),
        ?assertEqual('POST', Method),
        ?assertEqual(<<"/push/device-1">>, Path)
    end),
    step("And the body is aes128gcm, unreadable without the phone's keys", fun() ->
        ?assertEqual(<<"aes128gcm">>, maps:get(<<"content-encoding">>, Headers)),
        ?assertEqual(<<"application/octet-stream">>, maps:get(<<"content-type">>, Headers)),
        ?assertEqual(nomatch, binary:match(Body, <<"dinner">>))
    end),
    step("And the phone's browser decrypts it to the same text", fun() ->
        ?assertEqual({ok, <<"Dad: dinner is ready">>}, browser:decrypt(Body, Secret))
    end).

signs_the_request_with_vapid(_Config) ->
    {Sub, _Secret, Vapid} = step("Given a phone subscribed through the push service", fun() ->
        subscribed(201)
    end),
    ok = step("When the relay pushes a message", fun() ->
        webpush:send(Sub, <<"hi">>, Vapid, #{})
    end),
    #{headers := Headers} = received(),
    #{public := VapidPublic} = Vapid,
    {Jwt, Key} = step("Then the Authorization header is \"vapid t=<JWT>, k=<key>\"", fun() ->
        Auth = maps:get(<<"authorization">>, Headers),
        {match, [T, K]} = re:run(Auth, <<"^vapid t=([^, ]+), *k=([^, ]+)$">>,
                                 [{capture, all_but_first, binary}]),
        {T, K}
    end),
    step("And k is the relay's VAPID public key", fun() ->
        ?assertEqual(VapidPublic, browser:unb64(Key))
    end),
    [H64, C64, S64] = binary:split(Jwt, <<".">>, [global]),
    step("And the JWT is ES256 and its signature verifies with that key", fun() ->
        ?assertMatch(#{<<"alg">> := <<"ES256">>}, json:decode(browser:unb64(H64))),
        <<R:256, S:256>> = browser:unb64(S64),
        Der = public_key:der_encode('ECDSA-Sig-Value', {'ECDSA-Sig-Value', R, S}),
        ?assert(crypto:verify(ecdsa, sha256, <<H64/binary, ".", C64/binary>>, Der,
                              [VapidPublic, prime256v1]))
    end),
    step("And it names the push service's origin, expires within 24 h, and has a subject", fun() ->
        Claims = json:decode(browser:unb64(C64)),
        #{endpoint := Endpoint} = Sub,
        [Origin, _] = binary:split(Endpoint, <<"/push/">>),
        ?assertEqual(Origin, maps:get(<<"aud">>, Claims)),
        Exp = maps:get(<<"exp">>, Claims),
        Now = erlang:system_time(second),
        ?assert(Exp > Now andalso Exp =< Now + 24 * 3600),
        ?assertEqual(?SUBJECT, maps:get(<<"sub">>, Claims))
    end).

asks_for_ttl_and_urgency(_Config) ->
    {Sub, _Secret, Vapid} = step("Given a phone subscribed through the push service", fun() ->
        subscribed(201)
    end),
    ok = step("When the relay pushes an incoming call (TTL 45 s, urgency high)", fun() ->
        webpush:send(Sub, <<"call">>, Vapid, #{ttl => 45, urgency => high})
    end),
    #{headers := Headers} = received(),
    step("Then the request carries TTL: 45 and Urgency: high", fun() ->
        ?assertEqual(<<"45">>, maps:get(<<"ttl">>, Headers)),
        ?assertEqual(<<"high">>, maps:get(<<"urgency">>, Headers))
    end).

every_push_is_encrypted_afresh(_Config) ->
    {Json, _Secret} = browser:new_subscription(<<"https://push.example/x">>),
    {ok, Sub} = webpush:subscription(Json),
    step("When the relay encrypts the same text twice", fun() -> ok end),
    <<Salt1:16/binary, _:5/binary, Key1:65/binary, _/binary>> = webpush:encrypt(<<"same">>, Sub),
    <<Salt2:16/binary, _:5/binary, Key2:65/binary, _/binary>> = webpush:encrypt(<<"same">>, Sub),
    step("Then each body has its own salt and its own server key", fun() ->
        ?assertNotEqual(Salt1, Salt2),
        ?assertNotEqual(Key1, Key2)
    end).

a_gone_subscription_is_reported(_Config) ->
    {Sub, _Secret, Vapid} = step("Given a phone whose subscription the push service has dropped (410)", fun() ->
        subscribed(410)
    end),
    Result = step("When the relay pushes to it", fun() ->
        webpush:send(Sub, <<"hi">>, Vapid, #{})
    end),
    _ = received(),
    step("Then the relay is told it's gone, so it can delete the subscription", fun() ->
        ?assertEqual({error, gone}, Result)
    end).

the_largest_payload_fits_and_one_more_byte_is_refused(_Config) ->
    %% 4096-byte record - 86 header - 16 tag - 1 delimiter = 3993 (RFC 8291 §4).
    {Sub, Secret, Vapid} = step("Given a phone subscribed through the push service", fun() ->
        subscribed(201)
    end),
    Max = binary:copy(<<"a">>, 3993),
    ok = step("When the relay pushes 3993 bytes", fun() ->
        webpush:send(Sub, Max, Vapid, #{})
    end),
    #{body := Body} = received(),
    step("Then the phone reads all of it", fun() ->
        ?assertEqual({ok, Max}, browser:decrypt(Body, Secret))
    end),
    step("And 3994 bytes are refused without contacting the push service", fun() ->
        ?assertEqual({error, payload_too_large},
                     webpush:send(Sub, <<Max/binary, "a">>, Vapid, #{})),
        receive {push_service_got, _} -> ct:fail(unexpected_request)
        after 0 -> ok
        end
    end).

reads_the_subscription_json_from_the_web_app(_Config) ->
    {Json, #{ua_public := UaPub, auth := Auth}} =
        browser:new_subscription(<<"https://push.example/x">>),
    step("When the relay reads the JSON the web app sent", fun() -> ok end),
    step("Then it gets the endpoint and the decoded keys", fun() ->
        ?assertEqual({ok, #{endpoint => <<"https://push.example/x">>,
                            p256dh => UaPub, auth => Auth}},
                     webpush:subscription(Json))
    end),
    step("And malformed keys are refused", fun() ->
        Bad = Json#{<<"keys">> => #{<<"p256dh">> => <<"AAAA">>, <<"auth">> => <<"AAAA">>}},
        ?assertEqual({error, invalid_subscription}, webpush:subscription(Bad)),
        ?assertEqual({error, invalid_subscription}, webpush:subscription(#{}))
    end).

%% ---------------------------------------------------------------------------
%% Helpers

step(Label, Fun) ->
    ct:log("~ts", [Label]),
    Fun().

%% A fake push service answering Status, a browser subscribed to it, the
%% relay holding that subscription, and the relay's VAPID keys.
subscribed(Status) ->
    Endpoint = fake_push_service:start(Status),
    {Json, Secret} = browser:new_subscription(Endpoint),
    {ok, Sub} = webpush:subscription(Json),
    {Sub, Secret, webpush:vapid_keys(?SUBJECT)}.

received() ->
    receive {push_service_got, Request} -> Request
    after 5000 -> ct:fail(push_service_got_nothing)
    end.
