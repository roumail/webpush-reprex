%% Plays the PUSH SERVICE (Apple's or Google's push server in real life).
%%
%% start(Status) opens a plain-HTTP listener on 127.0.0.1, returns the
%% endpoint URL a browser would have been given, accepts ONE request, sends
%% it to the calling test process as
%%     {push_service_got, #{method, path, headers, body}}
%% and answers with Status (201 = accepted, 410 = subscription gone, ...).
%% Header names arrive lower-cased so tests don't depend on spelling.
-module(fake_push_service).
-export([start/1]).

start(Status) ->
    Owner = self(),
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {ip, loopback}]),
    {ok, Port} = inet:port(Listen),
    spawn_link(fun() -> serve_one(Listen, Status, Owner) end),
    iolist_to_binary(io_lib:format("http://127.0.0.1:~b/push/device-1", [Port])).

serve_one(Listen, Status, Owner) ->
    {ok, Sock} = gen_tcp:accept(Listen, 5000),
    %% Let the VM parse the request line and headers for us...
    ok = inet:setopts(Sock, [{packet, http_bin}]),
    {ok, {http_request, Method, {abs_path, Path}, _Version}} = gen_tcp:recv(Sock, 0, 5000),
    Headers = read_headers(Sock, #{}),
    %% ...then read the body as raw bytes.
    ok = inet:setopts(Sock, [{packet, raw}]),
    Body = case binary_to_integer(maps:get(<<"content-length">>, Headers, <<"0">>)) of
        0 -> <<>>;
        Len -> {ok, B} = gen_tcp:recv(Sock, Len, 5000), B
    end,
    Owner ! {push_service_got, #{method => Method, path => Path,
                                 headers => Headers, body => Body}},
    ok = gen_tcp:send(Sock, [<<"HTTP/1.1 ">>, integer_to_binary(Status), <<" ">>,
                             reason(Status),
                             <<"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n">>]),
    gen_tcp:close(Sock).

read_headers(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, {http_header, _, Name, _, Value}} -> read_headers(Sock, Acc#{lower(Name) => Value});
        {ok, http_eoh} -> Acc
    end.

lower(Name) when is_atom(Name) -> string:lowercase(atom_to_binary(Name));
lower(Name) -> string:lowercase(Name).

reason(201) -> <<"Created">>;
reason(404) -> <<"Not Found">>;
reason(410) -> <<"Gone">>;
reason(_) -> <<"Status">>.
