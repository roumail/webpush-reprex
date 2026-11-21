%% The manual check on a real phone, driven by ./push.sh.
%%
%%   keys  makes the relay's VAPID key pair once: the private half goes to
%%         vapid.local.json (gitignored, never published), the public half to
%%         docs/config.js, which the test page passes to pushManager.subscribe().
%%   send  pushes $PUSH_MESSAGE to the subscription the phone showed, saved in
%%         subscription.local.json (gitignored).
-module(webpush_manual).
-export([main/1]).

-define(KEYS, "vapid.local.json").
-define(SUBSCRIPTION, "subscription.local.json").
-define(CONFIG_JS, "docs/config.js").
%% VAPID contact: the test page's own public address.
-define(SUBJECT, <<"https://www.rohailtaimour.com/webpush-reprex/">>).

main(["keys"]) ->
    case filelib:is_file(?KEYS) of
        true ->
            done("~s already exists; delete it first (phones must subscribe again).~n", [?KEYS]);
        false ->
            #{public := Pub, private := Priv, subject := Sub} = webpush:vapid_keys(?SUBJECT),
            ok = file:write_file(?KEYS, json:encode(#{<<"public">> => b64(Pub),
                                                      <<"private">> => b64(Priv),
                                                      <<"subject">> => Sub})),
            ok = file:change_mode(?KEYS, 8#600),
            ok = file:write_file(?CONFIG_JS,
                                 ["// Made by ./push.sh keys. The relay's VAPID public key.\n",
                                  "const VAPID_PUBLIC_KEY = \"", b64(Pub), "\";\n"]),
            done("Wrote ~s (private, gitignored) and ~s (public).~n", [?KEYS, ?CONFIG_JS])
    end;
main(["send"]) ->
    Message = unicode:characters_to_binary(os:getenv("PUSH_MESSAGE", "Hello from Erlang")),
    #{<<"public">> := Pub, <<"private">> := Priv, <<"subject">> := Subject} = read_json(?KEYS),
    Vapid = #{public => unb64(Pub), private => unb64(Priv), subject => Subject},
    {ok, Sub} = webpush:subscription(read_json(?SUBSCRIPTION)),
    {ok, _} = application:ensure_all_started(webpush),
    Result = webpush:send(Sub, Message, Vapid, #{ttl => 300, urgency => high}),
    done("~p~n", [Result]);
main(_) ->
    done("usage: ./push.sh keys | ./push.sh send \"text\"~n", []).

read_json(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> json:decode(Bin);
        {error, enoent} -> done("~s is missing; see README.md.~n", [Path])
    end.

done(Format, Args) ->
    io:format(Format, Args),
    halt().

b64(Bin) -> base64:encode(Bin, #{mode => urlsafe, padding => false}).
unb64(Text) -> base64:decode(Text, #{mode => urlsafe, padding => false}).
