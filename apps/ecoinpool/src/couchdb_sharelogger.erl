
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

-module(couchdb_sharelogger).
-behaviour(gen_sharelogger).
-behaviour(gen_server).

-include("gen_sharelogger_spec.hrl").

-export([start_link/2, log_share/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    candidates_only,
    conn,
    known_dbs
}).

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
    CandidatesOnly = proplists:get_value(candidate_shares_only, Config, false),
    S = ecoinpool_db:get_couchdb_connection(),
    {ok, #state{candidates_only=CandidatesOnly, conn=S, known_dbs=sets:new()}}.

handle_call(_, _From, State) ->
    {reply, error, State}.

handle_cast(#share{
        timestamp=Timestamp,
        server_id=local,
        
        subpool_name=SubpoolName,
        worker_id=WorkerId,
        user_id=UserId,
        ip=IP,
        user_agent=UserAgent,
        
        state=State,
        reject_reason=RejectReason,
        hash=Hash,
        target=Target,
        block_num=BlockNum,
        prev_block=PrevBlock,
        round=Round,
        data=Data,
        
        auxpool_name=AuxpoolName,
        aux_state=AuxState,
        aux_hash=AuxHash,
        aux_target=AuxTarget,
        aux_block_num=AuxBlockNum,
        aux_prev_block=AuxPrevBlock,
        aux_round=AuxRound},
        SState=#state{
        candidates_only=CandidatesOnly,
        conn=S,
        known_dbs=KnownDBs}) ->
    
    KnownDBs1 = case sets:is_element(SubpoolName, KnownDBs) of
        true -> KnownDBs;
        false -> setup_shares_db(S, SubpoolName), sets:add_element(SubpoolName, KnownDBs)
    end,
    {ok, DB} = couchbeam:open_db(S, SubpoolName),
    if
        not CandidatesOnly; State =:= candidate ->
            case State of
                invalid ->
                    store_invalid_share_in_db(Timestamp, WorkerId, UserId, IP, UserAgent, RejectReason, Hash, undefined, Target, BlockNum, PrevBlock, Round, DB);
                _ ->
                    store_share_in_db(Timestamp, WorkerId, UserId, IP, UserAgent, State, Hash, undefined, Target, BlockNum, PrevBlock, Data, Round, DB)
            end;
        true ->
            ok
    end,
    case AuxpoolName of
        undefined ->
            {noreply, SState#state{known_dbs=KnownDBs1}};
        _ ->
            KnownDBs2 = case sets:is_element(AuxpoolName, KnownDBs) of
                true -> KnownDBs1;
                false -> setup_shares_db(S, AuxpoolName), sets:add_element(SubpoolName, KnownDBs1)
            end,
            {ok, AuxDB} = couchbeam:open_db(S, AuxpoolName),
            if
                not CandidatesOnly; AuxState =:= candidate ->
                    case AuxState of
                        invalid ->
                            store_invalid_share_in_db(Timestamp, WorkerId, UserId, IP, UserAgent, RejectReason, AuxHash, Hash, AuxTarget, AuxBlockNum, AuxPrevBlock, AuxRound, AuxDB);
                        _ ->
                            store_share_in_db(Timestamp, WorkerId, UserId, IP, UserAgent, AuxState, AuxHash, Hash, AuxTarget, AuxBlockNum, AuxPrevBlock, Data, AuxRound, AuxDB)
                    end;
                true ->
                    ok
            end,
            {noreply, SState#state{known_dbs=KnownDBs2}}
    end;

handle_cast(#share{}, State) -> % Ignore other shares (currently these are remote shares)
    {noreply, State}.

handle_info(_, State) ->
    {noreply, State}.

terminate(_, _) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

setup_shares_db(S, SubpoolName) ->
    case couchbeam:open_or_create_db(S, SubpoolName) of
        {ok, DB} ->
            lists:foreach(fun ecoinpool_db:check_design_doc/1, [
                {DB, "stats", "shares_db_stats.json"},
                {DB, "timed_stats", "shares_db_timed_stats.json"},
                {DB, "auth", "shares_db_auth.json"}
            ]),
            ok;
        {error, Error} ->
            log4erl:error(db, "shares_db - couchbeam:open_or_create_db/3 returned an error:~n~p", [Error]),
            error
    end.

-spec make_share_document(Timestamp :: erlang:timestamp(), WorkerId :: binary(), UserId :: term(), IP :: string(), UserAgent :: string(), State :: valid | candidate, Hash :: binary(), ParentHash :: binary() | undefined, Target :: binary(), BlockNum :: integer(), PrevBlock :: binary(), BData :: binary(), Round :: integer()) -> {[]}.
make_share_document(Timestamp, WorkerId, UserId, IP, UserAgent, State, Hash, ParentHash, Target, BlockNum, PrevBlock, BData, Round) ->
    {{YR,MH,DY}, {HR,ME,SD}} = calendar:now_to_datetime(Timestamp),
    filter_undefined({[
        {<<"worker_id">>, WorkerId},
        {<<"user_id">>, UserId},
        {<<"ip">>, binary:list_to_bin(IP)},
        {<<"user_agent">>, apply_if_defined(UserAgent, fun binary:list_to_bin/1)},
        {<<"timestamp">>, [YR,MH,DY,HR,ME,SD]},
        {<<"state">>, case State of valid -> <<"valid">>; candidate -> <<"candidate">> end},
        {<<"hash">>, ecoinpool_util:bin_to_hexbin(Hash)},
        {<<"parent_hash">>, apply_if_defined(ParentHash, fun ecoinpool_util:bin_to_hexbin/1)},
        {<<"target">>, ecoinpool_util:bin_to_hexbin(Target)},
        {<<"block_num">>, BlockNum},
        {<<"prev_block">>, apply_if_defined(PrevBlock, fun ecoinpool_util:bin_to_hexbin/1)},
        {<<"round">>, Round},
        {<<"data">>, case State of valid -> undefined; candidate -> base64:encode(BData) end}
    ]}).

-spec make_reject_share_document(Timestamp :: erlang:timestamp(), WorkerId :: binary(), UserId :: term(), IP :: string(), UserAgent :: string(), Reason :: reject_reason(), Hash :: binary() | undefined, ParentHash :: binary() | undefined, Target :: binary() | undefined, BlockNum :: integer() | undefined, PrevBlock :: binary() | undefined, Round :: integer()) -> {[]}.
make_reject_share_document(Timestamp, WorkerId, UserId, IP, UserAgent, Reason, Hash, ParentHash, Target, BlockNum, PrevBlock, Round) ->
    {{YR,MH,DY}, {HR,ME,SD}} = calendar:now_to_datetime(Timestamp),
    filter_undefined({[
        {<<"worker_id">>, WorkerId},
        {<<"user_id">>, UserId},
        {<<"ip">>, binary:list_to_bin(IP)},
        {<<"user_agent">>, apply_if_defined(UserAgent, fun binary:list_to_bin/1)},
        {<<"timestamp">>, [YR,MH,DY,HR,ME,SD]},
        {<<"state">>, <<"invalid">>},
        {<<"reject_reason">>, atom_to_binary(Reason, latin1)},
        {<<"hash">>, apply_if_defined(Hash, fun ecoinpool_util:bin_to_hexbin/1)},
        {<<"parent_hash">>, apply_if_defined(ParentHash, fun ecoinpool_util:bin_to_hexbin/1)},
        {<<"target">>, apply_if_defined(Target, fun ecoinpool_util:bin_to_hexbin/1)},
        {<<"block_num">>, BlockNum},
        {<<"prev_block">>, apply_if_defined(PrevBlock, fun ecoinpool_util:bin_to_hexbin/1)},
        {<<"round">>, Round}
    ]}).

apply_if_defined(undefined, _) ->
    undefined;
apply_if_defined(Value, Fun) ->
    Fun(Value).

filter_undefined({DocProps}) ->
    {lists:filter(fun ({_, undefined}) -> false; (_) -> true end, DocProps)}.

store_share_in_db(Timestamp, WorkerId, UserId, IP, UserAgent, State, Hash, ParentHash, Target, BlockNum, PrevBlock, BData, Round, DB) ->
    Doc = make_share_document(Timestamp, WorkerId, UserId, IP, UserAgent, State, Hash, ParentHash, Target, BlockNum, PrevBlock, BData, Round),
    try
        couchbeam:save_doc(DB, Doc),
        ok
    catch error:Reason ->
        log4erl:warn(db, "store_share_in_db: ignored error:~n~p", [Reason]),
        error
    end.

store_invalid_share_in_db(Timestamp, WorkerId, UserId, IP, UserAgent, Reason, Hash, ParentHash, Target, BlockNum, PrevBlock, Round, DB) ->
    Doc = make_reject_share_document(Timestamp, WorkerId, UserId, IP, UserAgent, Reason, Hash, ParentHash, Target, BlockNum, PrevBlock, Round),
    try
        couchbeam:save_doc(DB, Doc),
        ok
    catch error:Reason ->
        log4erl:warn(db, "store_invalid_share_in_db: ignored error:~n~p", [Reason]),
        error
    end.
