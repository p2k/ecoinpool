
%%
%% Copyright (C) 2011  Patrick "p2k" Schneider <patrick.p2k.schneider@gmail.com>
%%
%% This file is part of ecoinpool.
%%
%% ecoinpool is free software: you can redistribute it and/or modify
%% it under the terms of the GNU General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% ecoinpool is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU General Public License for more details.
%%
%% You should have received a copy of the GNU General Public License
%% along with ecoinpool.  If not, see <http://www.gnu.org/licenses/>.
%%

-module(mysql_sharelogger).
-behaviour(gen_sharelogger).

-include("gen_sharelogger_spec.hrl").
-include_lib("mysql/include/mysql.hrl").

-export([start_link/2, log_share/2]).

-export([defaults/0, connect/6, disconnect/1, fetch_result/2, get_field_names/2, get_timediff/1, get_query_size_limit/1, encode_elements/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(LoggerId, Config) ->
    gen_server:start_link({local, LoggerId}, sql_sharelogger, {LoggerId, ?MODULE, Config}, []).

log_share(LoggerId, Share) ->
    gen_server:cast(LoggerId, Share).

%% ===================================================================
%% SQL Share Logger callbacks
%% ===================================================================

defaults() ->
    {3306, <<"root">>}.

connect(LoggerId, Host, Port, User, Password, Database) ->
    LogFun = fun (_Module, _Line, Level, MsgFun) ->
        {Msg, Params} = MsgFun(),
        case Level of
            debug -> log4erl:debug(db, "~p:~n  " ++ Msg, [LoggerId] ++ Params);
            normal -> log4erl:info(db, "~p:~n  " ++ Msg, [LoggerId] ++ Params);
            warning -> log4erl:warn(db, "~p:~n  " ++ Msg, [LoggerId] ++ Params);
            error -> log4erl:error(db, "~p:~n  " ++ Msg, [LoggerId] ++ Params);
            _ -> ok
        end
    end,
    safe_connect(Host, Port, User, Password, Database, LogFun).

disconnect(Conn) ->
    case mysql_conn:quit(Conn, self()) of
        ok -> true;
        {error, _} -> exit(Conn, shutdown)
    end.

fetch_result(Conn, Query) ->
    case mysql_conn:fetch(Conn, iolist_to_binary(Query), self(), 30000) of
        {data, MyFieldsResult} -> {ok, mysql:get_result_rows(MyFieldsResult)};
        {updated, MyUpdateResult} -> {ok, mysql:get_result_affected_rows(MyUpdateResult)};
        {error, #mysql_result{error=Reason}} -> {error, Reason};
        Other -> Other
    end.

get_field_names(Conn, Table) ->
    {ok, Rows} = fetch_result(Conn, ["SHOW COLUMNS FROM `", Table, "`;"]),
    [FName || {FName, _, _, _, _, _} <- Rows].

get_timediff(Conn) ->
    {data, TimeDiffResult} = mysql_conn:fetch(Conn, <<"SELECT TIMEDIFF(NOW(), UTC_TIMESTAMP());">>, self(), 10000),
    [{TimeDiff}] = mysql:get_result_rows(TimeDiffResult),
    TimeDiff.

get_query_size_limit(Conn) ->
    {data, SizeLimitResult} = mysql_conn:fetch(Conn, <<"SHOW SESSION VARIABLES LIKE 'max_allowed_packet';">>, self(), 10000),
    [{<<"max_allowed_packet">>, BValue}] = mysql:get_result_rows(SizeLimitResult),
    list_to_integer(binary_to_list(BValue)) - 10240. % Provide some buffer, just in case.

encode_elements(Elements) ->
    [mysql:encode(Element) || Element <- Elements].

%% ===================================================================
%% Other functions
%% ===================================================================

safe_connect(Host, Port, User, Password, Database, LogFun) ->
    ParentPid = self(),
    ConnectorPid = spawn(fun () ->
        ParentPid ! {safe_connect, self(), mysql_conn:start(Host, Port, User, Password, Database, LogFun, undefined, undefined)}
    end),
    receive % This allows to queue more shares and other events while waiting
        {safe_connect, ConnectorPid, {ok, ConnPid}} ->
            link(ConnPid),
            {ok, ConnPid};
        {safe_connect, ConnectorPid, Other} ->
            Other
    end.
