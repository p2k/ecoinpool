
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

-module(btc_coindaemon).
-behaviour(gen_coindaemon).
-behaviour(gen_server).

-include("ecoinpool_workunit.hrl").
-include("btc_protocol_records.hrl").

-export([start_link/2, getwork_method/0, sendwork_method/0, share_target/0, post_workunit/1, encode_workunit/1, analyze_result/1, make_reply/1, send_result/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    subpool,
    url,
    auth,
    tag,
    pay_to,
    
    timer,
    block_num,
    last_fetch,
    
    memorypool,
    coinbase_tx
}).

-record(memorypool, {
    hash_prev_block,
    timestamp,
    bits,
    transactions,
    foldable_tree_hashes,
    coinbase_value
}).

%% ===================================================================
%% Gen_CoinDaemon API
%% ===================================================================

start_link(SubpoolId, Config) ->
    gen_server:start_link(?MODULE, [SubpoolId, Config], []).

getwork_method() ->
    getwork.

sendwork_method() ->
    getwork.

share_target() ->
    <<16#00000000ffff0000000000000000000000000000000000000000000000000000:256>>.

post_workunit(PID) ->
    gen_server:cast(PID, post_workunit).

encode_workunit(#workunit{data=Data}) ->
    HexData = ecoinpool_util:bin_to_hexbin(ecoinpool_util:endian_swap(Data)),
    Midstate = ecoinpool_hash:sha256_midstate(Data),
    {[
        {<<"data">>, <<HexData/binary, "000000800000000000000000000000000000000000000000000000000000000000000000000000000000000080020000">>},
        {<<"midstate">>, ecoinpool_util:bin_to_hexbin(Midstate)},
        {<<"hash1">>, <<"00000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000010000">>},
        {<<"target">>, <<"0000000000000000000000000000000000000000000000000000ffff00000000">>}
    ]}.

analyze_result([<<Data:160/bytes, _/binary>>]) ->
    case catch ecoinpool_util:hexbin_to_bin(Data) of
        {'EXIT', _} ->
            error;
        BDataBigEndian ->
            BData = ecoinpool_util:endian_swap(BDataBigEndian),
            BTCHeader = btc_protocol:decode_btc_header(BData),
            WorkunitId = workunit_id_from_btc_header(BTCHeader),
            Hash = ecoinpool_hash:dsha256_hash(BData),
            [{WorkunitId, Hash, BData}]
    end;
analyze_result(_) ->
    error.

make_reply([invalid]) ->
    false;
make_reply([_]) ->
    true.

send_result(PID, BData) ->
    gen_server:call(PID, {send_result, BData}).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([SubpoolId, Config]) ->
    process_flag(trap_exit, true),
    io:format("BTC CoinDaemin starting~n"),
    
    Host = binary:bin_to_list(proplists:get_value(host, Config, <<"localhost">>)),
    Port = proplists:get_value(port, Config, 8332),
    URL = lists:flatten(io_lib:format("http://~s:~b/", [Host, Port])),
    User = binary:bin_to_list(proplists:get_value(user, Config, <<"user">>)),
    Pass = binary:bin_to_list(proplists:get_value(pass, Config, <<"pass">>)),
    
    PayTo = btc_protocol:hash160_from_address(case proplists:get_value(pay_to, Config) of
        undefined ->
            get_default_payout_address(URL, {User, Pass});
        Address ->
            Address
    end),
    
    FullTag = case proplists:get_value(tag, Config) of
        Tag when is_binary(Tag), byte_size(Tag) > 0 ->
            <<"ecoinpool|", Tag/binary>>;
        _ ->
            <<"ecoinpool">>
    end,
    
    {ok, Timer} = timer:send_interval(200, poll_daemon), % Always poll 5 times per second
    {ok, #state{subpool=SubpoolId, url=URL, auth={User, Pass}, tag=FullTag, pay_to=PayTo, timer=Timer}}.

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(poll_daemon, State=#state{subpool=SubpoolId}) ->
    %getblocknumber
    {noreply, State};

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{timer=Timer}) ->
    timer:cancel(Timer),
    io:format("BTC CoinDaemon stopping~n"),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

send_req(URL, Auth, PostData) ->
    {ok, VSN} = application:get_key(ecoinpool, vsn),
    ibrowse:send_req(URL, [{"User-Agent", "ecoinpool/" ++ VSN}, {"Accept", "application/json"}], post, PostData, [{basic_auth, Auth}, {content_type, "application/json"}]).

get_default_payout_address(URL, Auth) ->
    case send_req(URL, Auth, "{\"method\":\"getaddressesbyaccount\",\"params\":[\"ecoinpool\"]}") of
        {ok, "200", _ResponseHeaders, ResponseBody} ->
            {Body} = ejson:decode(ResponseBody),
            case proplists:get_value(<<"result">>, Body) of
                [] ->
                    case send_req(URL, Auth, "{\"method\":\"getnewaddress\",\"params\":[\"ecoinpool\"]}") of
                        {ok, "200", _ResponseHeaders2, ResponseBody2} ->
                            {Body2} = ejson:decode(ResponseBody2),
                            {ok, proplists:get_value(<<"result">>, Body2)};
                        {ok, Status, _ResponseHeaders, ResponseBody2} ->
                            {error, binary:list_to_bin(io_lib:format("getnewaddress: Received HTTP ~s - Body: ~p", [Status, ResponseBody2]))};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                List ->
                    {ok, lists:last(List)}
            end;
        {ok, Status, _ResponseHeaders, ResponseBody} ->
            {error, binary:list_to_bin(io_lib:format("getaddressesbyaccount: Received HTTP ~s - Body: ~p", [Status, ResponseBody]))};
        {error, Reason} ->
            {error, Reason}
    end.

workunit_id_from_btc_header(#btc_header{hash_prev_block=HashPrevBlock, hash_merkle_root=HashMerkleRoot}) ->
    Data = <<HashPrevBlock/bytes, HashMerkleRoot/bytes>>,
    crypto:sha(Data).

make_btc_header(#memorypool{hash_prev_block=HashPrevBlock, timestamp=Timestamp, bits=Bits}, HashMerkleRoot) ->
    #btc_header{hash_prev_block=HashPrevBlock, hash_merkle_root=HashMerkleRoot, timestamp=Timestamp, bits=Bits}.

make_coinbase_tx(Tag, Bits, CoinbaseValue, PubkeyHash160, ScriptSigTrailer) ->
    TxIn = #btc_tx_in{
        prev_output_hash = <<0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0>>,
        prev_output_index = 16#ffffffff,
        signature_script = [Tag, Bits, 0 | ScriptSigTrailer]
    },
    TxOut = #btc_tx_out{
        value = CoinbaseValue,
        pk_script = [op_dup, op_hash160, PubkeyHash160, op_equalverify, op_checksig]
    },
    #btc_tx{tx_in=[TxIn], tx_out=[TxOut]}.

increment_coinbase_extra_nonce(Tx=#btc_tx{tx_in=[TxIn]}) ->
    #btc_tx_in{signature_script = [Tag, Bits, ExtraNonce | ScriptSigTrailer]} = TxIn,
    Tx#btc_tx{tx_in=[TxIn#btc_tx_in{signature_script = [Tag, Bits, ExtraNonce+1 | ScriptSigTrailer]}]}.

%assemble_block()
