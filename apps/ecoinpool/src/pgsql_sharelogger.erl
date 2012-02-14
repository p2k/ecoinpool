
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

-module(pgsql_sharelogger).
-behaviour(gen_sharelogger).

-include("gen_sharelogger_spec.hrl").

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
    {5432, <<"postgres">>}.

connect(_, Host, Port, User, Password, Database) ->
    pgsql:connect(Host, User, Password, [{port, Port}, {database, Database}]).

disconnect(Conn) ->
    pgsql:close(Conn).

fetch_result(Conn, Query) ->
    case pgsql:equery(Conn, Query) of
        {ok, _Columns, Rows} -> {ok, Rows};
        {ok, Count} -> {ok, Count};
        {ok, _Count, _Columns, Rows} -> {ok, Rows};
        {error, Error} -> {error, Error}
    end.

get_field_names(Conn, Table) ->
    {ok, Rows} = fetch_result(Conn, ["SELECT column_name FROM information_schema.columns WHERE table_name = '", Table, "';"]),
    [FName || {FName} <- Rows].

get_timediff(Conn) ->
    {ok, [{{TimeDiff, _, _}}]} = fetch_result(Conn, <<"SELECT AGE(CURRENT_TIMESTAMP, CURRENT_TIMESTAMP AT TIME ZONE 'UTC');">>),
    case TimeDiff of
        {H, M, S} when is_float(S) ->
            {H, M, round(S)};
        _ ->
            TimeDiff
    end.

get_query_size_limit(_) ->
    unlimited. % PostgreSQL ftw!

encode_elements(Elements) ->
    [encode_element(Element) || Element <- Elements].

encode_element(undefined) ->
    "null";
encode_element({{Year, Month, Day}, {Hour, Minute, Second}}) ->
    io_lib:format("'~4..0b-~2..0b-~2..0b ~2..0b:~2..0b:~2..0b'", [Year, Month, Day, Hour, Minute, Second]);
encode_element(E) ->
    mysql:encode(E).
