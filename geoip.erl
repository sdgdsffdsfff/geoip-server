%%! -smp auto +K true

%%================================
%% Geographic IP Informatin Server
%%================================

-module(geoip).
-author('wuhualiang@meituan.com').

-mode(compile).
-export([init/1, start/2, geoman/0, worker/2, snapshot/0]).

-define(DEV, _).
-ifdef(DEV).
-export([http_response/2]).
-export([special_ip/1]).
-export([multicast_ip/1]).
-export([invalid_ip/0]).
-export([normal_ip/0]).
-export([format/1]).
-export([free_proc/1]).
-export([ask_geoman/2]).
-export([id_to_name/5]).
-export([lookup/1]).
-export([lookup_ets/1]).
-endif.

-define(LOG_FILE, "logs").
-define(IPS_FILE, "ips.dump").
-define(GEO_FILE, "geo.meta").
-define(IPS_TABLE, mt_ips).
-define(GEO_TABLE, mt_geo).
-define(GEO_MANAGER, geoman).
-define(SNAPSHOT_INTV, 86400000).
-define(HIGH_WATER_MARK, 1000).

init(careful) ->
    ets:new(?IPS_TABLE, [set, public, named_table]),
    ets:new(?GEO_TABLE, [set, public, named_table]),
    ets:insert(?IPS_TABLE, {count, 0}),
    ets:insert(?GEO_TABLE, {{isp,      count}, 0}),
    ets:insert(?GEO_TABLE, {{country,  count}, 0}),
    ets:insert(?GEO_TABLE, {{province, count}, 0}),
    ets:insert(?GEO_TABLE, {{city,     count}, 0}),
    ets:insert(?GEO_TABLE, {{county,   count}, 0}),
    ets:tab2file(?IPS_TABLE, ?IPS_FILE),
    ets:tab2file(?GEO_TABLE, ?GEO_FILE),
    ets:delete(?IPS_TABLE),
    ets:delete(?GEO_TABLE),
    ok.

start(Port, Procs) ->
    register(?MODULE, self()),
    inets:start(),
    error_logger:logfile({open, ?LOG_FILE ++ time_suffix()}),
    {ok, ?IPS_TABLE} = ets:file2tab(?IPS_FILE),
    {ok, ?GEO_TABLE} = ets:file2tab(?GEO_FILE),
    GeoMan = spawn(?MODULE, geoman, []),
    register(?GEO_MANAGER, GeoMan),
    lists:map(fun worker_init/1, lists:seq(0, Procs-1)),
    spawn(?MODULE, snapshot, []),
    {ok, LSock} = gen_tcp:listen(Port, [{active, false}, {packet, http}]),
    loop(LSock, Procs),
    never_get_here.

%% ======== Internal Functions ======== %%

worker_init(X) when is_integer(X) ->
    Tid = ets:new(taskqueue, [set, public]),
    put({worker, X}, Tid),
    put({latest_task, X}, 0),
    Pid = spawn(?MODULE, worker, [Tid, 1]),
    register(list_to_atom("mt_worker_" ++ integer_to_list(X)), Pid).

worker(Tid, Todo) ->
    case ets:lookup(Tid, Todo) of
        [{_, Sock}] ->
            case gen_tcp:recv(Sock, 0, 200) of
                {ok, {http_request, 'GET', {abs_path, Path}, _}} ->
                    case Path of
                        "/api/ip/get/" ++ IP ->
                            {Code, Json} = lookup(IP),
                            Response = http_response(Code, Json),
                            inet:setopts(Sock, {send_timeout, 200}),
                            gen_tcp:send(Sock, Response);
                        _ -> pass
                    end;
                _ -> pass
            end,
            gen_tcp:close(Sock),
            worker(Tid, Todo + 1);
        [] ->
            timer:sleep(1),
            worker(Tid, Todo)
    end.

loop(LSock, Procs) ->
    {ok, Sock} = gen_tcp:accept(LSock),
    {X, Tid} = free_proc(Procs),
    Task = get({latest_task, X}) + 1,
    put({latest_task, X}, Task),
    ets:insert(Tid, {Task, Sock}),
    loop(LSock, Procs).

free_proc(Procs) -> free_proc(Procs, 1).
free_proc(Procs, Tried) ->
    {_, _, Y} = erlang:now(),
    X = Y rem Procs,
    Tid = get({worker, X}),
    Size = ets:info(Tid, size),
    if Size < ?HIGH_WATER_MARK ->
        {X, Tid};
    true ->
        if Procs == Tried ->
            {X, Tid};
        true ->
            free_proc(Procs, Tried + 1)
        end
    end.

geoman() ->
    receive
        {Type, Name, Pid} when is_pid(Pid) ->
            case ets:lookup(?GEO_TABLE, {Type, Name}) of
                [{_, Id}] ->
                    Pid ! Id;
                [] ->
                    [{_, Count}] = ets:lookup(?GEO_TABLE, {Type, count}),
                    Id = Count + 1,
                    ets:insert(?GEO_TABLE, {{Type, Id}, Name}),
                    ets:insert(?GEO_TABLE, {{Type, Name}, Id}),
                    ets:insert(?GEO_TABLE, {{Type, count}, Id}),
                    ets:tab2file(?GEO_TABLE, ?GEO_FILE),
                    Pid ! Id
            end;
        _ -> pass
    end,
    geoman().

ask_geoman(Type, Name) ->
    case ets:lookup(?GEO_TABLE, {Type, Name}) of
        [{_, Id}] -> Id;
        [] ->
            geoman ! {Type, Name, self()},
            receive Id -> Id end
    end.

snapshot() ->
    timer:sleep(?SNAPSHOT_INTV),
    Suffix = time_suffix(),
    ets:tab2file(?IPS_TABLE, ?IPS_FILE ++ Suffix),
    ets:tab2file(?GEO_TABLE, ?GEO_FILE ++ Suffix),
    snapshot().

lookup(IP) when is_list(IP) ->
    case inet:parse_ipv4strict_address(IP) of
        {ok, {A, B, C, D}} ->
            if
                A == 0;
                A == 10;
                A == 100, (B band 2#11000000) == 64;
                A == 127;
                [A, B] == [169, 254];
                A == 172, (B band 2#11110000) == 16;
                [A, B, C] == [192, 0, 0];
                [A, B, C] == [192, 0, 2];
                [A, B, C] == [192, 88, 99];
                [A, B] == [192, 168];
                A == 198, (B band 2#11111110) == 18;
                [A, B, C] == [198, 51, 100];
                [A, B, C] == [203, 0, 113];
                (A band 2#11110000) == 240;
                [A, B, C, D] == [255, 255, 255, 255] ->
                    special_ip(IP);
                (A band 2#11110000) == 224 ->
                    multicast_ip(IP);
                true ->
                    lookup_ets(IP)
            end;
        _ -> invalid_ip()
    end.

%% mt_ips value format:
%%     2 |  10 |       8 |       12 |   16 |     16 |    256
%% ------+-----+---------+----------+------+--------+--------
%%  flag | ISP | country | province | city | county | bitmap
lookup_ets(IP) ->
    {A, B, C, D} = inet:parse_ipv4_address(IP),
    Key = (A bsl 16) + (B bsl 8) + C,
    case ets:lookup(?IPS_TABLE, Key) of
        [{_, Val}] ->
            L = 255 - D,
            <<_:2, ISP:10, Country:8, Province:12, City:16,
              County:16, _:L, X:1, _:D>> = Val,
            case X of
                1 ->
                    Geo = id_to_name(ISP, Country, Province, City, County),
                    {200, format([IP | Geo])};
                0 ->
                    case ets:lookup(?IPS_TABLE, (Key bsl 8) + D) of
                        [{_, Val2}] ->
                            <<_:2, ISP2:10, Country2:8, Province2:12, 
                              City2:16, County2:16>> = Val2,
                            Geo2 = id_to_name(ISP2, Country2, Province2,
                                              City2, County2),
                            {200, format([IP | Geo2])};
                        [] -> taobao_api(IP)
                    end
            end;
        [] -> taobao_api(IP)
    end.

taobao_api(IP) ->
    URL = "http://ip.taobao.com/service/getIpInfo.php?ip=" ++ IP,
    case httpc:request(get, {URL, []}, [], [{full_result, false}]) of
        {ok, {200, Json}} ->
            Decoded = try
                mochijson2:decode(Json)
            catch
                error: _Reason -> error
            end,
            case Decoded of
                [{<<"code">>, 0}, {<<"data">>, Info}] ->
                    {_, ISP} = lists:keyfind(<<"isp">>, 1, Info),
                    {_, Country} = lists:keyfind(<<"country">>, 1, Info),
                    {_, Province} = lists:keyfind(<<"region">>, 1, Info),
                    {_, City} = lists:keyfind(<<"city">>, 1, Info),
                    {_, County} = lists:keyfind(<<"county">>, 1, Info),
                    All = [IP, ISP, Country, Province, City, County],
                    save(All),
                    {200, format(All)};
                _ -> invalid_ip()
            end;
        _ -> invalid_ip()
    end.

save([IP, ISP, Country, Province, City, County]) ->
    ISP_id  = ask_geoman(isp, ISP),
    Cntr_id = ask_geoman(country, Country),
    Prvn_id = ask_geoman(province, Province),
    City_id = ask_geoman(city, City),
    Cnt_id  = ask_geoman(county, County),
    GeoBin = <<0:2, ISP_id:10, Cntr_id:8, Prvn_id:12, City_id:16, Cnt_id:16>>,
    {ok, {A, B, C, D}} = inet:parse_ipv4_address(IP),
    Key = (A bsl 16) + (B bsl 8) + C,
    L = 255 - D,
    case ets:lookup(?IPS_TABLE, Key) of
        [{_, <<GeoBin:64/bits, BM1:L/bits, X:1, BM2:D/bits>>}] ->
            case X of
                1 -> pass;
                0 ->
                    Val = <<GeoBin/bits, BM1/bits, 1:1, BM2/bits>>,
                    ets:insert(?IPS_TABLE, {Key, Val}),
                    incr_ips_count()
            end;
        [_] ->
            ets:insert(?IPS_TABLE, {Key*256 + D, GeoBin}),
            incr_ips_count();
        [] ->
            Val = <<GeoBin/bits, 0:L, 1:1, 0:D>>,
            ets:insert(?IPS_TABLE, {Key, Val}),
            incr_ips_count()
    end.

incr_ips_count() ->
    [{_, Count}] = ets:lookup(?IPS_TABLE, count),
    ets:insert(?IPS_TABLE, {count, Count + 1}).

http_response(Code, Json) ->
    Status = case Code of
        200 -> "HTTP/1.1 200 OK\r\nServer: Erlang\r\n";
        400 -> "HTTP/1.1 BAD REQUEST\r\nServer: Erlang\r\n"
    end,
    {{Year, Month, Mday}, {Hour, Min, Sec}} = erlang:universaltime(),
    Wday = calendar:day_of_the_week({Year, Month, Mday}),
    Args = [lists:nth(Wday, weekdays()), Mday, lists:nth(Month, months()),
            Year, Hour, Min, Sec],
    Date = io_lib:format("Date: ~s, ~b ~s ~b ~b:~b:~b GMT\r\n", Args),
    lists:concat([Status, Date,
                  "Content-Type: application/json\r\n",
                  "Transfer-Encoding: chunked\r\n",
                  "Connection: close\r\n\r\n",
                  Json]).

id_to_name(ISP_id, Country_id, Province_id, City_id, County_id) ->
    [{_, ISP}]      = ets:lookup(?GEO_TABLE, {isp,      ISP_id}),
    [{_, Country}]  = ets:lookup(?GEO_TABLE, {country,  Country_id}),
    [{_, Province}] = ets:lookup(?GEO_TABLE, {province, Province_id}),
    [{_, City}]     = ets:lookup(?GEO_TABLE, {city,     City_id}),
    [{_, County}]   = ets:lookup(?GEO_TABLE, {county,   County_id}),
    [ISP, Country, Province, City, County].

format(Args) when is_list(Args) ->
    % [IP, ISP, Country, Province, City, County] = Args
    io_lib:format(normal_ip(), Args).

normal_ip() ->
    "{\"ip\":\"~s\", \"isp\":\"~s\", \"country\":\"~s\"," ++
    "\"province\":\"~s\", \"city\":\"~s\", \"county\":\"~s\"}".

special_ip(IP) ->
    Json = "{\"province\":\"https://www.iana.org/assignments/iana-ipv4-special-registry/iana-ipv4-special-registry.xhtml\"," ++
           "\"city\":\"\"," ++ 
           "\"ip\":\"" ++ IP ++ "\"," ++
           "\"isp\":\"\"," ++
           "\"county\":\"\"," ++
           "\"country\":\"IANA Special-Purpose Address\"}",
    {200, Json}.

multicast_ip(IP) ->
    Json = "{\"province\":\"https://www.iana.org/assignments/multicast-addresses/multicast-addresses.xhtml\"," ++
           "\"city\":\"\"," ++ 
           "\"ip\":\"" ++ IP ++ "\"," ++
           "\"isp\":\"\"," ++
           "\"county\":\"\"," ++
           "\"country\":\"IANA Multicast Address\"}",
    {200, Json}.

invalid_ip() ->
    {400, "{\"message\":\"Invalid IP\"}"}.

time_suffix() ->
    {{Y, M, D}, {H, Mi, S}} = erlang:localtime(),
    Sfx1 = integer_to_list(Y * 10000 + M * 100 + D),
    Sfx2 = integer_to_list(H * 10000 + Mi * 100 + S),
    Pad = lists:duplicate(6 - length(Sfx2), $0), 
    lists:concat(["-", Sfx1, "-", Pad, Sfx2]).

months() ->
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].

weekdays() ->
    ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].

