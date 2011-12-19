
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

-module(nmc_auxdaemon).
-behaviour(gen_auxdaemon).
-behaviour(gen_server).

-include("../ebitcoin/include/btc_protocol_records.hrl").
-include("ecoinpool_workunit.hrl").

-export([start_link/2, get_aux_work/1, send_aux_pow/3]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    subpool,
    url,
    auth,
    
    poll_timer,
    ebtc_id,
    block_num,
    prev_block,
    
    last_fetch,
    auxblock_data
}).

%% ===================================================================
%% Gen_AuxDaemon API
%% ===================================================================

start_link(SubpoolId, Config) ->
    gen_server:start_link(?MODULE, [SubpoolId, Config], []).

get_aux_work(PID) ->
    gen_server:call(PID, get_aux_work, infinity).

send_aux_pow(PID, AuxHash, AuxPOW) ->
    gen_server:call(PID, {send_aux_pow, AuxHash, AuxPOW}, infinity).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([SubpoolId, Config]) ->
    process_flag(trap_exit, true),
    log4erl:warn(daemon, "NMC AuxDaemon starting..."),
    
    Host = binary:bin_to_list(proplists:get_value(host, Config, <<"localhost">>)),
    Port = proplists:get_value(port, Config, 8332),
    URL = lists:flatten(io_lib:format("http://~s:~b/", [Host, Port])),
    User = binary:bin_to_list(proplists:get_value(user, Config, <<"user">>)),
    Pass = binary:bin_to_list(proplists:get_value(pass, Config, <<"pass">>)),
    
    {PollTimer, EBtcId} = case proplists:get_value(ebitcoin_client_id, Config) of
        undefined ->
            {ok, T} = timer:send_interval(200, poll_daemon), % Always poll 5 times per second
            {T, undefined};
        Id ->
            ebitcoin_client:add_blockchange_listener(Id, self()),
            {undefined, Id}
    end,
    
    ecoinpool_server:auxdaemon_ready(SubpoolId, ?MODULE, self()),
    
    {ok, #state{subpool=SubpoolId, url=URL, auth={User, Pass}, poll_timer=PollTimer, ebtc_id=EBtcId}}.

handle_call(get_aux_work, _From, OldState) ->
    % Check if a new block must be fetched
    State = fetch_block_with_state(OldState),
    % Extract state variables
    #state{block_num=BlockNum, prev_block=PrevBlock, auxblock_data=AuxblockData} = State,
    % Send reply
    case AuxblockData of
        {AuxHash, Target, ChainId} ->
            {reply, #auxwork{aux_hash=AuxHash, target=Target, chain_id=ChainId, block_num=BlockNum, prev_block=PrevBlock}, State};
        undefined ->
            {reply, {error, <<"aux block could not be created">>}, State}
    end;

handle_call({send_aux_pow, AuxHash, AuxPOW}, _From, State=#state{url=URL, auth=Auth}) ->
    try
        {reply, do_send_aux_pow(URL, Auth, AuxHash, AuxPOW), State}
    catch error:_ ->
        {reply, {error, <<"exception in nmc_auxdaemon:do_send_aux_pow/4">>}, State}
    end;

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast({ebitcoin_blockchange, _, PrevBlock, BlockNum}, State) ->
    {noreply, fetch_block_with_state(State#state{block_num={pushed, BlockNum + 1}, prev_block=PrevBlock})};

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(poll_daemon, State) ->
    {noreply, fetch_block_with_state(State)};

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{poll_timer=PollTimer, ebtc_id=EBtcId}) ->
    case PollTimer of
        undefined ->
            ebitcoin_client:remove_blockchange_listener(EBtcId, self());
        _ ->
            timer:cancel(PollTimer)
    end,
    log4erl:warn(daemon, "NMC AuxDaemon terminated."),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

get_block_number(URL, Auth) ->
    {ok, "200", _ResponseHeaders, ResponseBody} = ecoinpool_util:send_http_req(URL, Auth, "{\"method\":\"getblocknumber\"}"),
    {Body} = ejson:decode(ResponseBody),
    proplists:get_value(<<"result">>, Body) + 1.

do_get_aux_block(URL, Auth) ->
    {ok, "200", _ResponseHeaders, ResponseBody} = ecoinpool_util:send_http_req(URL, Auth, "{\"method\":\"getauxblock\"}"),
    {Body} = ejson:decode(ResponseBody),
    {Result} = proplists:get_value(<<"result">>, Body),
    
    Target = ecoinpool_util:byte_reverse(ecoinpool_util:hexbin_to_bin(proplists:get_value(<<"target">>, Result))),
    AuxHash = ecoinpool_util:byte_reverse(ecoinpool_util:hexbin_to_bin(proplists:get_value(<<"hash">>, Result))),
    ChainId = proplists:get_value(<<"chainid">>, Result),
    
    {AuxHash, Target, ChainId}.

check_fetch_now(_, #state{last_fetch=undefined}) ->
    {true, starting};
check_fetch_now(_, #state{block_num=undefined}) ->
    {true, starting};
check_fetch_now(Now, #state{poll_timer=undefined, block_num=BlockNum, last_fetch=LastFetch}) -> % Non-polling
    case BlockNum of
        {pushed, NewBlockNum} ->
            {true, {new_block, NewBlockNum}};
        _ ->
            case timer:now_diff(Now, LastFetch) of
                Diff when Diff > 15000000 -> % Force data fetch every 15s
                    {true, timeout};
                _ ->
                    false
            end
    end;
check_fetch_now(Now, #state{url=URL, auth=Auth, block_num=BlockNum, last_fetch=LastFetch}) -> % Polling
    case timer:now_diff(Now, LastFetch) of
        Diff when Diff < 200000 -> % Prevent rpc call if less than 200ms passed
            false;
        Diff when Diff > 15000000 -> % Force data fetch every 15s
            {true, timeout};
        _ ->
            try
                case get_block_number(URL, Auth) of
                    BlockNum ->
                        false;
                    NewBlockNum ->
                        {true, {new_block, NewBlockNum}}
                end
            catch error:_ ->
                {true, error}
            end
    end.

fetch_block_with_state(State=#state{subpool=SubpoolId, url=URL, auth=Auth, ebtc_id=EBtcId}) ->
    Now = erlang:now(),
    case check_fetch_now(Now, State) of
        false ->
            State;
        {true, Reason} ->
            case Reason of
                {new_block, _} ->
                    ecoinpool_server:new_aux_block_detected(SubpoolId, ?MODULE);
                _ ->
                    ok
            end,
            
            AuxblockData = do_get_aux_block(URL, Auth),
            
            case Reason of
                {new_block, BlockNum} ->
                    State#state{block_num=BlockNum, last_fetch=Now, auxblock_data=AuxblockData};
                starting ->
                    TheBlockNum = case EBtcId of
                        undefined ->
                            get_block_number(URL, Auth);
                        _ ->
                            ebitcoin_client:last_block_num(EBtcId)
                    end,
                    State#state{block_num=TheBlockNum, last_fetch=Now, auxblock_data=AuxblockData};
                _ ->
                    State#state{last_fetch=Now, auxblock_data=AuxblockData}
            end
    end.

do_send_aux_pow(URL, Auth, <<AuxHash:256/big>>, AuxPOW) ->
    BData = btc_protocol:encode_auxpow(AuxPOW),
    HexHash = ecoinpool_util:list_to_hexstr(binary:bin_to_list(<<AuxHash:256/little>>)),
    HexData = ecoinpool_util:list_to_hexstr(binary:bin_to_list(BData)),
    PostData = "{\"method\":\"getauxblock\",\"params\":[\"" ++ HexHash ++ "\",\"" ++ HexData ++ "\"]}",
    log4erl:debug(daemon, "nmc_auxdaemon: Sending upstream: ~s", [PostData]),
    case ecoinpool_util:send_http_req(URL, Auth, PostData) of
        {ok, "200", _ResponseHeaders, ResponseBody} ->
            {Body} = ejson:decode(ResponseBody),
            case proplists:get_value(<<"result">>, Body) of
                true ->
                    accepted;
                _ ->
                    rejected
            end;
        {ok, Status, _ResponseHeaders, ResponseBody} ->
            {error, binary:list_to_bin(io_lib:format("do_send_aux_pow: Received HTTP ~s - Body: ~p", [Status, ResponseBody]))};
        {error, Reason} ->
            {error, Reason}
    end.
