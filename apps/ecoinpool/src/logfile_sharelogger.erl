
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

-module(logfile_sharelogger).
-behaviour(gen_event).

-include("ecoinpool_misc_types.hrl").
-include("ecoinpool_db_records.hrl").

-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3]).

%% ===================================================================
%% Gen_Event callbacks
%% ===================================================================

init(Options) ->
    FieldInfo = lists:zip(record_info(fields, share), lists:seq(2, record_info(size, share))),
    LogRemote = proplists:get_value(log_remote, Options, false),
    AlwaysLogData = proplists:get_value(always_log_data, Options, false),
    FieldIds = case proplists:get_value(fields, Options) of
        undefined when LogRemote ->
            lists:seq(2, record_info(size, share));
        undefined ->
            lists:seq(2, record_info(size, share)-1);
        L when is_list(L) ->
            lists:foldr(
                fun
                    (FieldName, Acc) when is_binary(FieldName) ->
                        case proplists:get_value(binary_to_atom(FieldName, utf8), FieldInfo) of
                            undefined ->
                                Acc;
                            Pos ->
                                [Pos | Acc]
                        end;
                    (_, Acc) ->
                        Acc
                end,
                [],
                L
            )
    end,
    {ok, {LogRemote, AlwaysLogData, FieldIds}}.

handle_event(#subpool{}, State) ->
    {ok, State};

handle_event(Share=#share{state=State, is_local=IsLocal}, {LogRemote, AlwaysLogData, FieldIds}) when IsLocal; LogRemote ->
    ShareNow = if
        AlwaysLogData; State =:= candidate ->
            Share;
        true ->
            Share#share{data=undefined}
    end,
    log_data([{I, element(I, ShareNow)} || I <- FieldIds]),
    {ok, {LogRemote, AlwaysLogData, FieldIds}};

handle_event(_, State) ->
    {ok, State}.

handle_call(_, State) ->
    {ok, error, State}.

handle_info(_, State) ->
    {ok, State}.

terminate(_, _) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

log_data(L) ->
    log4erl:info(shares, "~s", [string:join(lists:map(fun write_data/1, L), ";")]).

write_data({_, undefined}) ->
    [];
write_data({#share.state, State}) ->
    case State of
        invalid -> "0";
        valid -> "1";
        candidate -> "2"
    end;
write_data({#share.timestamp, TS={_, _, MicroSecs}}) ->
    {{YR,MH,DY}, {HR,ME,SD}} = calendar:now_to_datetime(TS),
    MS = MicroSecs div 1000,
    io_lib:format("\"~4..0b-~2..0b-~2..0b ~2..0b:~2..0b:~2..0b.~3..0b\"", [YR,MH,DY,HR,ME,SD,MS]);
write_data({I, Hash}) when I =:= #share.hash; I =:= #share.parent_hash; I =:= #share.target; I =:= #share.prev_block ->
    [$", ecoinpool_util:bin_to_hexbin(Hash), $"];
write_data({#share.data, Data}) ->
    [$", base64:encode(Data), $"];
write_data({_, S}) when is_binary(S); is_list(S) ->
    [$", add_quotes(S), $"];
write_data({_, true}) ->
    "1";
write_data({_, false}) ->
    "0";
write_data({_, I}) when is_integer(I) ->
    integer_to_list(I);
write_data({_, A}) when is_atom(A) ->
    [$", atom_to_list(A), $"].

add_quotes(S) when is_binary(S) ->
    add_quotes(binary_to_list(S));
add_quotes(S) ->
    [case C of $" -> [$\\,$"]; $\\ -> [$\\,$\\]; _ -> C end || C <- S].
