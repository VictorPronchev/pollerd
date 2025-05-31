% Erlang SNMP Poller with MySQL backend and Prometheus exporter

-module(snmp_poller).
-export([start/0, init/0, poller/1, metrics_handler/2]).

-define(POLL_INTERVAL, 30000). % 30 seconds

-include_lib("snmp/include/snmp_types.hrl").

start() ->
    application:start(snmp),
    application:start(cowboy),
    application:start(mysql),
    init().

init() ->
    % Start ETS table
    ets:new(snmp_metrics, [named_table, public, set]),

    % Start HTTP server
    Dispatch = cowboy_router:compile([
        {'_', [{"/metrics", ?MODULE, []}]}
    ]),
    {ok, _} = cowboy:start_clear(http, [{port, 8080}], #{env => #{dispatch => Dispatch}}),

    % Start polling loop
    spawn(?MODULE, poller, [[]]).

poller(_) ->
    % Load OID definitions from files
    OIDs = load_oids("./oids"),

    % Connect to MySQL and fetch devices
    {ok, Conn} = mysql:start_link(#{user => "user", password => "pass", database => "snmp", host => "localhost"}),
    {ok, Result} = mysql:query(Conn, "SELECT ip, version, community, user, auth_proto, auth_pass, priv_proto, priv_pass, location, vendor FROM devices"),

    % Parse rows
    {_, Rows} = Result,
    lists:foreach(fun(Row) -> spawn(fun() -> poll_device(Row, OIDs) end) end, Rows),

    timer:sleep(?POLL_INTERVAL),
    poller([]).

poll_device({IP, "2c", Community, _, _, _, _, _, Location, Vendor}, OIDs) ->
    %% SNMPv2c
    snmp:open_session(IP, [{community, Community}, {version, v2c}]),
    fetch_metrics(IP, OIDs, Location, Vendor);

poll_device({IP, "3", _, User, AuthProto, AuthPass, PrivProto, PrivPass, Location, Vendor}, OIDs) ->
    %% SNMPv3
    Usm = #{user => User,
            auth => {list_to_atom(string:lowercase(AuthProto)), AuthPass},
            priv => {list_to_atom(string:lowercase(PrivProto)), PrivPass}},
    snmp:open_session(IP, [{version, v3}, {user, Usm}]),
    fetch_metrics(IP, OIDs, Location, Vendor).

fetch_metrics(IP, OIDs, Location, Vendor) ->
    lists:foreach(fun({Metric, OID}) ->
        case snmp:get(IP, OID) of
            {ok, RawValue} ->
                Value = normalize(Metric, RawValue),
                ets:insert(snmp_metrics, {{IP, Metric}, {Value, Location, Vendor}});
            _ -> ok
        end
    end, OIDs).

normalize("uptime", Centiseconds) ->
    % Convert uptime from centiseconds to seconds
    round(Centiseconds / 100);

normalize("mem_total", KB) -> round(KB / 1024); % MB
normalize("mem_free", KB) -> round(KB / 1024);
normalize("disk_used", KB) -> round(KB / 1024);
normalize(_, Value) when is_number(Value) -> Value;
normalize(_, _) -> 0.

metrics_handler(Req, State) ->
    Metrics = ets:tab2list(snmp_metrics),
    Lines = lists:map(fun({{IP, Metric}, {Value, Location, Vendor}}) ->
        io_lib:format("~s{device=\"~s\",location=\"~s\",vendor=\"~s\"} ~p\n", [Metric, IP, Location, Vendor, Value])
    end, Metrics),
    Body = lists:flatten(Lines),
    {ok, Req2} = cowboy_req:reply(200, #{"content-type" => "text/plain"}, Body, Req),
    {ok, Req2, State}.

load_oids(Dir) ->
    {ok, Files} = file:list_dir(Dir),
    lists:flatten([load_oid_file(filename:join(Dir, F)) || F <- Files]).

load_oid_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            Lines = binary:split(Bin, <<"\n">>, [global]),
            [parse_oid_line(binary_to_list(L)) || L <- Lines, L =/= <<>>];
        _ -> []
    end.

parse_oid_line(Line) ->
    case string:split(Line, ",", all) of
        [Name, OID] -> {string:trim(Name), string:trim(OID)};
        _ -> {unknown, "0.0"}
    end.
