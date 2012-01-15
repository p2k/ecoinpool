
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

-module(ecoinpool_share_broker).
-behaviour(gen_server).

-include("ecoinpool_misc_types.hrl").
-include("ecoinpool_db_records.hrl").
-include("ecoinpool_workunit.hrl").

-export([
    start_link/0,
    
    add_share_logger/3,
    remove_share_logger/2,
    
    notify_subpool/1,
    
    notify_share/1,
    notify_share/6,
    notify_invalid_share/4,
    notify_invalid_share/5,
    notify_invalid_share/6
]).

% Callbacks from gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ecoinpool_share_broker_sup).
-define(MAX_RESTART_COUNT, 5).
-define(MAX_RESTART_INTERVAL, 5000).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec add_share_logger(Id :: binary(), Type :: binary(), Options :: [conf_property()]) -> term().
add_share_logger(Id, Type, Options) ->
    gen_server:call(?SERVER, {add_share_logger, Id, Type, Options}).

-spec remove_share_logger(Id :: binary(), Type :: binary()) -> term().
remove_share_logger(Id, Type) ->
    gen_server:call(?SERVER, {remove_share_logger, Id, Type}).

-spec notify_subpool(Subpool :: subpool()) -> ok.
notify_subpool(Subpool) ->
    gen_event:notify(?MODULE, Subpool).

-spec notify_share(Share :: share()) -> ok.
notify_share(Share=#share{}) ->
    gen_event:notify(?MODULE, Share).

-spec notify_share(Subpool :: subpool(), Peer :: peer(), Worker :: worker(), Workunit :: workunit(), Hash :: binary(), Candidates :: [candidate()]) -> ok.
notify_share(#subpool{id=SubpoolId, name=SubpoolName, round=Round, aux_pool=Auxpool},
            Peer,
            #worker{id=WorkerId, user_id=UserId, name=WorkerName},
            #workunit{target=Target, block_num=BlockNum, prev_block=PrevBlock, data=BData, aux_work=AuxWork, aux_work_stale=AuxWorkStale},
            Hash,
            Candidates) ->
    % This code will change if multi aux chains are supported
    Timestamp = os:timestamp(),
    {MainState, AuxState} = lists:foldl(
        fun
            (main, {_, AS}) -> {candidate, AS};
            (aux, {MS, _}) -> {MS, candidate};
            (_, Acc) -> Acc
        end,
        {valid, valid},
        Candidates
    ),
    case Auxpool of
        #auxpool{name=AuxpoolName, round=AuxRound} when AuxWork =/= undefined ->
            if
                AuxWorkStale ->
                    notify_share(#share{
                        timestamp = Timestamp,
                        subpool_id = SubpoolId,
                        is_aux = true,
                        pool_name = AuxpoolName,
                        worker_id = WorkerId,
                        worker_name = WorkerName,
                        user_id = UserId,
                        ip = element(1, Peer),
                        user_agent = element(2, Peer),
                        
                        state = invalid,
                        reject_reason = stale,
                        parent_hash = Hash,
                        round = AuxRound
                    });
                true ->
                    #auxwork{aux_hash=AuxHash, target=AuxTarget, block_num=AuxBlockNum, prev_block=AuxPrevBlock} = AuxWork,
                    notify_share(#share{
                        timestamp = Timestamp,
                        subpool_id = SubpoolId,
                        is_aux = true,
                        pool_name = AuxpoolName,
                        worker_id = WorkerId,
                        worker_name = WorkerName,
                        user_id = UserId,
                        ip = element(1, Peer),
                        user_agent = element(2, Peer),
                        
                        state = AuxState,
                        hash = AuxHash,
                        parent_hash = Hash,
                        target = AuxTarget,
                        block_num = AuxBlockNum,
                        prev_block = AuxPrevBlock,
                        round = AuxRound,
                        data = BData
                    })
            end;
        _ ->
            ok
    end,
    
    notify_share(#share{
        timestamp = Timestamp,
        subpool_id = SubpoolId,
        pool_name = SubpoolName,
        worker_id = WorkerId,
        worker_name = WorkerName,
        user_id = UserId,
        ip = element(1, Peer),
        user_agent = element(2, Peer),
        
        state = MainState,
        hash = Hash,
        target = Target,
        block_num = BlockNum,
        prev_block = PrevBlock,
        round = Round,
        data = BData
    }).

-spec notify_invalid_share(Subpool :: subpool(), Peer :: peer(), Worker :: worker(), Reason :: reject_reason()) -> ok.
notify_invalid_share(Subpool, Peer, Worker, Reason) ->
    notify_invalid_share(Subpool, Peer, Worker, undefined, undefined, Reason).

-spec notify_invalid_share(Subpool :: subpool(), Peer :: peer(), Worker :: worker(), Hash :: binary(), Reason :: reject_reason()) -> ok.
notify_invalid_share(Subpool, Peer, Worker, Hash, Reason) ->
    notify_invalid_share(Subpool, Peer, Worker, undefined, Hash, Reason).

-spec notify_invalid_share(Subpool :: subpool(), Peer :: peer(), Worker :: worker(), Workunit :: workunit() | undefined, Hash :: binary() | undefined, Reason :: reject_reason()) -> ok.
notify_invalid_share(#subpool{id=SubpoolId, name=SubpoolName, round=Round, aux_pool=Auxpool}, Peer, #worker{id=WorkerId, user_id=UserId, name=WorkerName}, Workunit, Hash, Reason) ->
    % This code will change if multi aux chains are supported
    Timestamp = os:timestamp(),
    case Auxpool of
        #auxpool{name=AuxpoolName, round=AuxRound} ->
            case Workunit of
                #workunit{aux_work=#auxwork{aux_hash=AuxHash, target=AuxTarget, block_num=AuxBlockNum, prev_block=AuxPrevBlock}} ->
                    notify_share(#share{
                        timestamp = Timestamp,
                        subpool_id = SubpoolId,
                        is_aux = true,
                        pool_name = AuxpoolName,
                        worker_id = WorkerId,
                        worker_name = WorkerName,
                        user_id = UserId,
                        ip = element(1, Peer),
                        user_agent = element(2, Peer),
                        
                        state = invalid,
                        reject_reason = Reason,
                        hash = AuxHash,
                        parent_hash = Hash,
                        target = AuxTarget,
                        block_num = AuxBlockNum,
                        prev_block = AuxPrevBlock,
                        round = AuxRound
                    });
                _ ->
                    notify_share(#share{
                        timestamp = Timestamp,
                        subpool_id = SubpoolId,
                        is_aux = true,
                        pool_name = AuxpoolName,
                        worker_id = WorkerId,
                        worker_name = WorkerName,
                        user_id = UserId,
                        ip = element(1, Peer),
                        user_agent = element(2, Peer),
                        
                        state = invalid,
                        reject_reason = Reason,
                        parent_hash = Hash,
                        round = AuxRound
                    })
            end;
        _ ->
            ok
    end,
    
    case Workunit of
        #workunit{target=Target, block_num=BlockNum, prev_block=PrevBlock} ->
            notify_share(#share{
                timestamp = Timestamp,
                subpool_id = SubpoolId,
                pool_name = SubpoolName,
                worker_id = WorkerId,
                worker_name = WorkerName,
                user_id = UserId,
                ip = element(1, Peer),
                user_agent = element(2, Peer),
                
                state = invalid,
                reject_reason = Reason,
                hash = Hash,
                target = Target,
                block_num = BlockNum,
                prev_block = PrevBlock,
                round = Round
            });
        _ ->
            notify_share(#share{
                timestamp = Timestamp,
                subpool_id = SubpoolId,
                pool_name = SubpoolName,
                worker_id = WorkerId,
                worker_name = WorkerName,
                user_id = UserId,
                ip = element(1, Peer),
                user_agent = element(2, Peer),
                
                state = invalid,
                reject_reason = Reason,
                hash = Hash,
                round = Round
            })
    end.

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([]) ->
    case gen_event:start_link({local, ?MODULE}) of
        {ok, Pid} ->
            gen_event:add_sup_handler(Pid, longpolling_sharelogger, []),
            {ok, dict:from_list([{longpolling_sharelogger, {[], undefined, 0}}])};
        {error, Error} ->
            {error, Error}
    end.

handle_call({add_share_logger, Id, Type, Options}, _From, State) ->
    OptionsWithId = [{id, Id} | Options],
    Module = list_to_atom(lists:concat([Type, "_sharelogger"])),
    case gen_event:add_sup_handler(?MODULE, {Module, Id}, OptionsWithId) of
        ok ->
            {reply, ok, dict:store({Module, Id}, {OptionsWithId, undefined, 0}, State)};
        Result ->
            log4erl:error("Could not add share logger ~p, reason:~n~p", [{Module, Id}, Result]),
            {reply, Result, State}
    end;

handle_call({remove_share_logger, Id, Type}, _From, State) ->
    Module = list_to_atom(lists:concat([Type, "_sharelogger"])),
    Result = gen_event:delete_handler(?MODULE, {Module, Id}, shutdown),
    {reply, Result, dict:erase({Module, Id}, State)};

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({gen_event_EXIT, Handler, _Reason}, State) ->
    case dict:find(Handler, State) of
        {ok, {Options, LastRestart, RestartCount}} ->
            Now = erlang:now(),
            Diff = case LastRestart of
                undefined ->
                    ?MAX_RESTART_INTERVAL + 1;
                _ ->
                    timer:now_diff(Now, LastRestart) div 1000
            end,
            {NewState, DoRestart} = if
                Diff > ?MAX_RESTART_INTERVAL -> % Reset restart counter
                    log4erl:error("Restarting crashed sharelogger: ~p", [Handler]),
                    {dict:store(Handler, {Options, Now, 1}, State), true};
                RestartCount >= ?MAX_RESTART_COUNT -> % Give up
                    log4erl:error("Giving up sharelogger: ~p", [Handler]),
                    {dict:erase(Handler, State), false};
                true -> % Retry
                    log4erl:error("Restarting crashed sharelogger (~bx): ~p", [RestartCount + 1, Handler]),
                    {dict:store(Handler, {Options, LastRestart, RestartCount + 1}, State), true}
            end,
            if
                DoRestart ->
                    case gen_event:add_sup_handler(?MODULE, Handler, Options) of
                        ok ->
                            {noreply, NewState};
                        Result ->
                            log4erl:error("Could not restart sharelogger: ~p - ~p", [Handler, Result]),
                            {noreply, dict:erase(Handler, State)}
                    end;
                true ->
                    {noreply, NewState}
            end;
        error ->
            log4erl:error("Unknown sharelogger: ~p", [Handler]),
            {noreply, State}
    end;

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.
