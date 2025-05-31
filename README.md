Aрхитектурата и основните компоненти на паралелен SNMP poller на Erlang, който:

Чете списък от SNMPv2 и SNMPv3 устройства с креденшъли от MySQL.

Изпълнява паралелен SNMP polling.

Експортира резултатите във формат, подходящ за Prometheus (чрез HTTP endpoint).

🧱 Компоненти
1. MySQL модул – за извличане на конфигурацията
Използваме epgsql или mysql-otp библиотека.

erlang
% snmp_config:fetch_targets/0
fetch_targets() ->
    % Свързване и извличане на устройства с креденшъли
    {ok, C} = mysql:start_link([{host, "localhost"}, {user, "snmpuser"}, {password, "snmppass"}, {database, "snmp"}]),
    {ok, _, Rows} = mysql:query(C, "SELECT ip, version, community, username, authpass, privpass FROM devices"),
    mysql:stop(C),
    Rows.
2. SNMP poller
Използваме snmp модула на Erlang/OTP:

erlang
% snmp_poller:poll(Target)
poll({IP, "2c", Community, _, _, _}) ->
    snmp:open(),
    snmp:config([{agent, IP}, {community, Community}]),
    case snmp:get(IP, "1.3.6.1.2.1.1.3.0") of
        {ok, Value} -> {IP, Value};
        Error -> {IP, Error}
    end;
poll({IP, "3", _, User, AuthPass, PrivPass}) ->
    snmp:open(),
    snmp:config([{agent, IP}, {version, v3}, {user, User}, {auth, sha, AuthPass}, {priv, aes, PrivPass}]),
    case snmp:get(IP, "1.3.6.1.2.1.1.3.0") of
        {ok, Value} -> {IP, Value};
        Error -> {IP, Error}
    end.
3. Паралелен изпълнител
Използваме erlang:spawn/1 или async чрез task модула.

erlang
start_polling() ->
    Targets = snmp_config:fetch_targets(),
    Pids = [spawn(fun() -> Result = snmp_poller:poll(T), snmp_result_store:store(Result) end) || T <- Targets],
    ok.
4. Прометей експортер
Създава cowboy или elli HTTP сървър, който отговаря на /metrics.

erlang
% metrics_handler:handle/2
handle(Req, State) ->
    Metrics = snmp_result_store:get_all_as_prometheus(),
    cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain">>}, Metrics, Req).
5. Пример за експортиран Prometheus формат
bash
# HELP snmp_device_uptime_seconds Uptime of device in seconds
# TYPE snmp_device_uptime_seconds gauge
snmp_device_uptime_seconds{device="192.168.1.1"} 123456
🚀 Как да го стартирате
snmp_supervisor стартира cowboy, mysql и poll_worker.

poll_worker изпълнява polling на всеки 60 секунди и буферира в ETS или GenServer.

/metrics endpoint показва последните измерени стойности.

🔧 Необходими библиотеки
mysql-otp

[snmp](вграден в OTP)

cowboy за HTTP
