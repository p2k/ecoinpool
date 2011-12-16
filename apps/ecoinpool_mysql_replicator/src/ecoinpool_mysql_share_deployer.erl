
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

-module(ecoinpool_mysql_share_deployer).
-behaviour(gen_server).

-export([
    start_link/4,
    start_link/5
]).

% Callbacks from gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    state_file_name,
    
    worker_db_start_ref,
    worker_db_changes_pid,
    main_db_start_ref,
    main_db_changes_pid,
    main_db_seq,
    aux_db_start_ref,
    aux_db_changes_pid,
    aux_db_seq,
    
    my_pool_id,
    my_table,
    my_timer
}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(ConfigIdStr, WorkerDb, MainPoolDb, MyPoolId, MyTable, MyInterval) ->
    start_link(ConfigIdStr, WorkerDb, MainPoolDb, undefined, MyPoolId, MyTable, MyInterval).

start_link(ConfigIdStr, WorkerDb, MainPoolDb, AuxPoolDb, MyPoolId, MyTable, MyInterval) ->
    gen_server:start_link(?MODULE, [ConfigIdStr, WorkerDb, MainPoolDb, AuxPoolDb, MyPoolId, MyTable, MyInterval], []).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([ConfigIdStr, WorkerDb, MainPoolDb, AuxPoolDb, MyPoolId, MyTable, MyInterval]) ->
    % Trap exit
    process_flag(trap_exit, true),
    % Load any stored sequence numbers
    StateFileName = ConfigIdStr ++ ".state",
    {MainPoolDbSeq, AuxPoolDbSeq} = case file:consult(StateFileName) of
        {ok, Terms} ->
            {proplists:get_value(main_seq, Terms, 0), proplists:get_value(aux_seq, Terms, 0)};
        {error, X} when is_atom(X) ->
            {0, 0}
    end,
    % Get the worker DB sequence number
    {ok, {WorkerDbInfo}} = couchbeam:db_info(WorkerDb),
    WorkerDbSeq = proplists:get_value(<<"update_seq">>, WorkerDbInfo),
    % Start monitors
    case start_change_monitor(WorkerDb, WorkerDbSeq) of
        {ok, WorkerDbStartRef, WorkerDbChangesPid} ->
            case start_change_monitor(MainPoolDb, MainPoolDbSeq) of
                {ok, MainPoolDbStartRef, MainPoolDbChangesPid} ->
                    case start_change_monitor(AuxPoolDb, AuxPoolDbSeq) of
                        {ok, AuxPoolDbStartRef, AuxPoolDbChangesPid} ->
                            % Start the timer
                            MyTimer = case MyInterval of
                                0 -> undefined;
                                _ -> {ok, T} = timer:send_interval(MyInterval * 1000, insert_shares), T
                            end,
                            {ok, #state{
                                state_file_name = StateFileName,
                                worker_db_start_ref = WorkerDbStartRef,
                                worker_db_changes_pid = WorkerDbChangesPid,
                                main_db_start_ref = MainPoolDbStartRef,
                                main_db_changes_pid = MainPoolDbChangesPid,
                                main_db_seq = MainPoolDbSeq,
                                aux_db_start_ref = AuxPoolDbStartRef,
                                aux_db_changes_pid = AuxPoolDbChangesPid,
                                aux_db_seq = AuxPoolDbSeq,
                                my_pool_id = MyPoolId,
                                my_table = MyTable,
                                my_timer = MyTimer
                            }};
                        {error, Error} ->
                            stop_change_monitor(MainPoolDbChangesPid),
                            stop_change_monitor(WorkerDbChangesPid),
                            {stop, Error}
                    end;
                {error, Error} ->
                    stop_change_monitor(WorkerDbChangesPid),
                    {stop, Error}
            end;
        {error, Error} ->
            {stop, Error}
    end.

handle_call(_Message, _From, State) ->
    {reply, {error, no_such_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({change, StartRef, Msg}, State) ->
    

handle_info({'DOWN', MRef, process, Pid, _},

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{state_file_name=StateFileName, worker_db_changes_pid=WorkerDbChangesPid, main_db_changes_pid=MainPoolDbChangesPid, main_db_seq=MainPoolDbSeq, aux_db_changes_pid=AuxPoolDbChangesPid, aux_db_seq=AuxPoolDbSeq, my_timer=MyTimer}) ->
    stop_change_monitor(WorkerDbChangesPid),
    stop_change_monitor(MainPoolDbChangesPid),
    stop_change_monitor(AuxPoolDbChangesPid),
    case MyTimer of
        undefined -> ok;
        _ -> timer:cancel(MyTimer)
    end,
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.


start_change_monitor(undefined, _) ->
    {ok, undefined, undefined};
start_change_monitor(DB, Since) ->
    case couchbeam_changes:stream(DB, self(), [continuous, heartbeat, include_docs, {since, Since}]) of
        Ret={ok, StartRef, ChangesPid} ->
            erlang:monitor(process, ChangesPid),
            unlink(ChangesPid),
            Ret;
        Error ->
            Error
    end.

stop_change_monitor(undefined) ->
    ok;
stop_change_monitor(Pid) ->
    catch exit(Pid, normal),
    ok.

write_state_file(StateFileName, MainPoolDbSeq, AuxPoolDbSeq) ->
    if
        MainPoolDbSeq > 0 ->
            MainData = [io_lib:write({main_seq, MainPoolDbSeq}), "."],
            WriteData = if
                AuxPoolDbSeq > 0 ->
                    [MainData, 10, io_lib:write({aux_seq, AuxPoolDbSeq}), "."];
                true ->
                    MainData
            end,
            file:write_file(StateFileName, WriteData);
        true ->
            file:delete(StateFileName)
    end.