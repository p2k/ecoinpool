
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
    
    add_sharelogger/3,
    remove_sharelogger/1,
    
    notify_share/1,
    notify_share/6,
    notify_invalid_share/4,
    notify_invalid_share/5,
    notify_invalid_share/6
]).

% Callbacks from gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec add_sharelogger(Id :: binary(), Type :: binary(), Config :: [conf_property()]) -> term().
add_sharelogger(Id, Type, Config) ->
    gen_server:call(?MODULE, {add_sharelogger, Id, Type, Config}).

-spec remove_sharelogger(Id :: binary()) -> term().
remove_sharelogger(Id) ->
    gen_server:call(?MODULE, {remove_sharelogger, Id}).

-spec notify_share(Share :: share()) -> ok.
notify_share(Share) ->
    gen_server:cast(?MODULE, {notify_share, Share}).

-spec notify_share(Subpool :: subpool(), Peer :: peer(), Worker :: worker(), Workunit :: workunit(), Hash :: binary(), Candidates :: [candidate()]) -> ok.
notify_share(#subpool{id=SubpoolId, name=SubpoolName, round=Round, aux_pool=Auxpool},
            Peer,
            #worker{id=WorkerId, user_id=UserId, name=WorkerName},
            #workunit{target=Target, block_num=BlockNum, prev_block=PrevBlock, data=BData, aux_work=AuxWork, aux_work_stale=AuxWorkStale},
            Hash,
            Candidates) ->
    % This code will change if multi aux chains are supported
    {MainState, AuxState} = lists:foldl(
        fun
            (main, {_, AS}) -> {candidate, AS};
            (aux, {MS, _}) -> {MS, candidate};
            (_, Acc) -> Acc
        end,
        {valid, valid},
        Candidates
    ),
    Share = #share{
        timestamp = os:timestamp(),
        subpool_id = SubpoolId,
        subpool_name = SubpoolName,
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
    },
    case Auxpool of
        #auxpool{name=AuxpoolName, round=AuxRound} when AuxWork =/= undefined ->
            if
                AuxWorkStale ->
                    notify_share(Share#share{
                        auxpool_name = AuxpoolName,
                        aux_state = invalid,
                        aux_round = AuxRound
                    });
                true ->
                    #auxwork{aux_hash=AuxHash, target=AuxTarget, block_num=AuxBlockNum, prev_block=AuxPrevBlock} = AuxWork,
                    notify_share(Share#share{
                        auxpool_name = AuxpoolName,
                        aux_state = AuxState,
                        aux_hash = AuxHash,
                        aux_target = AuxTarget,
                        aux_block_num = AuxBlockNum,
                        aux_prev_block = AuxPrevBlock,
                        aux_round = AuxRound
                    })
            end;
        _ ->
            notify_share(Share)
    end.

-spec notify_invalid_share(Subpool :: subpool(), Peer :: peer(), Worker :: worker(), Reason :: reject_reason()) -> ok.
notify_invalid_share(Subpool, Peer, Worker, Reason) ->
    notify_invalid_share(Subpool, Peer, Worker, undefined, undefined, Reason).

-spec notify_invalid_share(Subpool :: subpool(), Peer :: peer(), Worker :: worker(), Hash :: binary(), Reason :: reject_reason()) -> ok.
notify_invalid_share(Subpool, Peer, Worker, Hash, Reason) ->
    notify_invalid_share(Subpool, Peer, Worker, undefined, Hash, Reason).

-spec notify_invalid_share(Subpool :: subpool(), Peer :: peer(), Worker :: worker(), Workunit :: workunit() | undefined, Hash :: binary() | undefined, Reason :: reject_reason()) -> ok.
notify_invalid_share(#subpool{id=SubpoolId, name=SubpoolName, round=Round, aux_pool=Auxpool}, Peer, #worker{id=WorkerId, user_id=UserId, name=WorkerName}, Workunit, Hash, Reason) ->
    % This code will change if multi aux chains are supported
    Share = #share{
        timestamp = os:timestamp(),
        subpool_id = SubpoolId,
        subpool_name = SubpoolName,
        worker_id = WorkerId,
        worker_name = WorkerName,
        user_id = UserId,
        ip = element(1, Peer),
        user_agent = element(2, Peer),
        
        state = invalid,
        reject_reason = Reason,
        hash = Hash,
        round = Round
    },
    Share1 = case Workunit of
        #workunit{target=Target, block_num=BlockNum, prev_block=PrevBlock} ->
            Share#share{
                target = Target,
                block_num = BlockNum,
                prev_block = PrevBlock
            };
        _ ->
            Share
    end,
    case Auxpool of
        #auxpool{name=AuxpoolName, round=AuxRound} ->
            case Workunit of
                #workunit{aux_work=#auxwork{aux_hash=AuxHash, target=AuxTarget, block_num=AuxBlockNum, prev_block=AuxPrevBlock}} ->
                    notify_share(Share1#share{
                        auxpool_name = AuxpoolName,
                        aux_state = invalid,
                        aux_hash = AuxHash,
                        aux_target = AuxTarget,
                        aux_block_num = AuxBlockNum,
                        aux_prev_block = AuxPrevBlock,
                        aux_round = AuxRound
                    });
                _ ->
                    notify_share(Share1#share{
                        auxpool_name = AuxpoolName,
                        aux_state = invalid,
                        aux_round = AuxRound
                    })
            end;
        _ ->
            notify_share(Share1)
    end.

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([]) ->
    % Trap exit
    process_flag(trap_exit, true),
    % Check if crash recovery is in effect
    case ecoinpool_sup:crash_fetch(?MODULE) of
        {ok, Shareloggers} ->
            log4erl:error("Share Broker recovering from a crash, restarting ~b share logger(s)", [length(Shareloggers)]),
            gen_server:cast(self(), {start_shareloggers, Shareloggers});
        error -> % If not, start the default longpolling sharelogger
            gen_server:cast(self(), {start_shareloggers, [{longpolling_sharelogger, longpolling_sharelogger, []}]})
    end,
    {ok, []}.

handle_call({add_sharelogger, Id, Type, Config}, _From, State) ->
    LoggerId = binary_to_atom(iolist_to_binary([Id, "_sharelogger"]), utf8),
    Module = binary_to_atom(iolist_to_binary([Type, "_sharelogger"]), utf8),
    case ecoinpool_sharelogger_sup:start_sharelogger(LoggerId, Module, Config) of
        ok ->
            {reply, ok, [{LoggerId, Module, Config} | State]};
        {error, Reason} ->
            log4erl:error("Could not start share logger ~p, reason:~n~p", [LoggerId, Reason]),
            {reply, {error, Reason}, State}
    end;

handle_call({remove_sharelogger, Id}, _From, State) ->
    LoggerId = binary_to_atom(iolist_to_binary([Id, "_sharelogger"]), utf8),
    Result = ecoinpool_sharelogger_sup:stop_sharelogger(LoggerId),
    {reply, Result, lists:delete(LoggerId, State)}.

handle_cast({start_shareloggers, Shareloggers}, CurrentShareloggers) ->
    {noreply, start_shareloggers(Shareloggers, CurrentShareloggers)};

handle_cast({notify_share, Share}, CurrentShareloggers) ->
    lists:foreach(fun ({LoggerId, Module, _}) -> Module:log_share(LoggerId, Share) end, CurrentShareloggers),
    {noreply, CurrentShareloggers}.

handle_info(_Message, State) ->
    {noreply, State}.

terminate(Reason, State) ->
    % Check for crashes
    case Reason of
        normal -> ok;
        shutdown -> ok;
        {shutdown, _} -> ok;
        _ -> ecoinpool_sup:crash_store(?MODULE, State)
    end,
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

start_shareloggers(Shareloggers, State) ->
    lists:foldl(
        fun ({LoggerId, Module, Config}, StateAcc) ->
            case ecoinpool_sharelogger_sup:start_sharelogger(LoggerId, Module, Config) of
                ok ->
                    [{LoggerId, Module, Config} | StateAcc];
                {error, Reason} ->
                    log4erl:error("Could not start share logger ~p, reason:~n~p", [LoggerId, Reason]),
                    StateAcc
            end
        end,
        State,
        Shareloggers
    ).
