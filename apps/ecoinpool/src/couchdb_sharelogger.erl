
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
-behaviour(gen_event).

-include("ecoinpool_misc_types.hrl").
-include("ecoinpool_db_records.hrl").

-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3]).

%% ===================================================================
%% Gen_Event callbacks
%% ===================================================================

init(_) ->
    S = ecoinpool_db:get_couchdb_connection(),
    {ok, S}.

handle_event(#subpool{name=SubpoolName, aux_pool=AuxPool}, S) ->
    setup_shares_db(S, SubpoolName),
    case AuxPool of
        #auxpool{name=AuxpoolName} ->
            setup_shares_db(S, AuxpoolName);
        _ ->
            ok
    end,
    {ok, S};

handle_event(#share{
        timestamp=Timestamp,
        pool_name=PoolName,
        worker_id=WorkerId,
        user_id=UserId,
        ip=IP,
        user_agent=UserAgent,
        state=State,
        reject_reason=RejectReason,
        hash=Hash,
        parent_hash=ParentHash,
        target=Target,
        block_num=BlockNum,
        prev_block=PrevBlock,
        round=Round,
        data=Data,
        is_local=true}, S) ->
    
    {ok, DB} = couchbeam:open_db(S, PoolName),
    case State of
        invalid ->
            store_invalid_share_in_db(Timestamp, WorkerId, UserId, IP, UserAgent, RejectReason, Hash, ParentHash, Target, BlockNum, PrevBlock, Round, DB);
        _ ->
            store_share_in_db(Timestamp, WorkerId, UserId, IP, UserAgent, State, Hash, ParentHash, Target, BlockNum, PrevBlock, Data, Round, DB)
    end,
    {ok, S};

handle_event(#share{}, S) -> % Ignore other shares (currently these are remote shares)
    {ok, S}.

handle_call(_, S) ->
    {ok, error, S}.

handle_info(_, S) ->
    {ok, S}.

terminate(_, _) ->
    ok.

code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

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
