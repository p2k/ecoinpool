
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
-behaviour(gen_sharelogger).
-behaviour(gen_server).

-include("gen_sharelogger_spec.hrl").

-export([start_link/2, log_share/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(LoggerId, Config) ->
    gen_server:start_link({local, LoggerId}, ?MODULE, Config, []).

log_share(LoggerId, Share) ->
    gen_server:cast(LoggerId, Share).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init(Config) ->
    FieldInfo = lists:zip(record_info(fields, share), lists:seq(2, record_info(size, share))),
    LogRemote = proplists:get_value(log_remote, Config, false),
    AlwaysLogData = proplists:get_value(always_log_data, Config, false),
    FieldIds = case proplists:get_value(fields, Config) of
        undefined when LogRemote ->
            lists:seq(2, record_info(size, share));
        undefined ->
            lists:seq(2, record_info(size, share)) -- [#share.server_id];
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

handle_call(_, _From, State) ->
    {reply, error, State}.

handle_cast(Share=#share{server_id=ServerId, state=State, aux_state=AuxState}, {LogRemote, AlwaysLogData, FieldIds}) when ServerId =:= local; LogRemote ->
    ShareNow = if
        AlwaysLogData; State =:= candidate; AuxState =:= candidate ->
            Share;
        true ->
            Share#share{data=undefined}
    end,
    log_data([{I, element(I, ShareNow)} || I <- FieldIds]),
    {noreply, {LogRemote, AlwaysLogData, FieldIds}}.

handle_info(_, State) ->
    {noreply, State}.

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
write_data({I, State}) when I =:= #share.state; I =:= #share.aux_state ->
    case State of
        invalid -> "0";
        valid -> "1";
        candidate -> "2"
    end;
write_data({#share.timestamp, TS={_, _, MicroSecs}}) ->
    {{YR,MH,DY}, {HR,ME,SD}} = calendar:now_to_datetime(TS),
    MS = MicroSecs div 1000,
    io_lib:format("\"~4..0b-~2..0b-~2..0b ~2..0b:~2..0b:~2..0b.~3..0b\"", [YR,MH,DY,HR,ME,SD,MS]);
write_data({I, Hash}) when I =:= #share.hash; I =:= #share.aux_hash; I =:= #share.target;  I =:= #share.aux_target; I =:= #share.prev_block; I =:= #share.aux_prev_block ->
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
