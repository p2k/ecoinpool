
%%
%% Copyright (C) 2011  Patrick "p2k" Schneider <patrick.p2k.schneider@gmail.com>
%%
%% This file is part of ebitcoin.
%%
%% ebitcoin is free software: you can redistribute it and/or modify
%% it under the terms of the GNU General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% ebitcoin is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU General Public License for more details.
%%
%% You should have received a copy of the GNU General Public License
%% along with ebitcoin.  If not, see <http://www.gnu.org/licenses/>.
%%

-module(ebitcoin_client).
-behaviour(gen_server).

-include("btc_protocol_records.hrl").

-export([
    start_link/3
]).

% Callbacks from gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    chain,
    node_nonce,
    peer_host,
    peer_port,
    socket,
    
    last_block_num,
    last_block_hash,
    block_invq,
    getdataq,
    resync_mode = false,
    
    pkt_buf
}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(Chain, PeerHost, PeerPort) when Chain =:= bitcoin; Chain =:= bitcoin_testnet; Chain =:= namecoin; Chain =:= namecoin_testnet ->
    gen_server:start_link({local, Chain}, ?MODULE, [Chain, PeerHost, PeerPort], []).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([Chain, PeerHost, PeerPort]) ->
    % Trap exit
    process_flag(trap_exit, true),
    % Setup the chain database
    ok = ebitcoin_db:setup_chain_dbs(Chain),
    % Get last block information
    {BlockNum, BlockHash} = ebitcoin_db:get_last_block_info(Chain),
    % Connect
    log4erl:warn(ebitcoin, "~p: Connecting to ~s:~b...", [Chain, PeerHost, PeerPort]),
    Socket = case gen_tcp:connect(PeerHost, PeerPort, [binary, inet, {packet, raw}]) of
        {ok, S} ->
            log4erl:warn(ebitcoin, "~p: Connection established.", [Chain]),
            S;
        {error, Reason} ->
            log4erl:fatal(ebitcoin, "~p: Could not connect!", [Chain]),
            error(Reason)
    end,
    gen_server:cast(Chain, start_handshake),
    InitialState = #state{
        chain = Chain,
        node_nonce = crypto:rand_uniform(0, 16#10000000000000000),
        peer_host = PeerHost,
        peer_port = PeerPort,
        socket = Socket,
        last_block_num = BlockNum,
        last_block_hash = BlockHash,
        pkt_buf = <<>>
    },
    {ok, InitialState}.

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast(start_handshake, State=#state{chain=Chain, node_nonce=NodeNonce, socket=Socket, last_block_num=BlockNum}) ->
    {ok, {RecvAddress, RecvPort}} = inet:peername(Socket),
    {ok, {FromAddress, FromPort}} = inet:sockname(Socket),
    {MSec, Sec, _} = erlang:now(),
    Version = #btc_version{
        version = 50000,
        services = 1,
        timestamp = MSec * 1000000 + Sec,
        addr_recv = #btc_net_addr{services=1, ip=RecvAddress, port=RecvPort},
        addr_from = #btc_net_addr{services=1, ip=FromAddress, port=FromPort},
        nonce = NodeNonce,
        sub_version_num = <<>>,
        start_height = BlockNum
    },
    gen_tcp:send(Socket, pack_message(Chain, Version)),
    {noreply, State};

handle_cast({resync, FinalBlock}, State=#state{chain=Chain, socket=Socket, last_block_num=BlockNum, resync_mode=R}) ->
    NewR = case R of
        {_, _, FinalBlock} ->
            log4erl:info(ebitcoin, "~p: Resync: Requesting next blocks...", [Chain]),
            R;
        _ ->
            if
                is_binary(FinalBlock) ->
                    log4erl:info(ebitcoin, "~p: Entering resync mode...", [Chain]),
                    {0, undefined, FinalBlock};
                is_integer(FinalBlock) ->
                    log4erl:info(ebitcoin, "~p: Entering resync mode, getting ~b block(s)...", [Chain, FinalBlock-BlockNum]),
                    {0, FinalBlock-BlockNum, FinalBlock}
            end
    end,
    GetHeaders = make_getheaders(Chain, BlockNum),
    gen_tcp:send(Socket, pack_message(Chain, GetHeaders)),
    {noreply, State#state{resync_mode=NewR}};

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({tcp, _Socket, NewData}, State=#state{pkt_buf=Buffer}) ->
    Data = <<Buffer/binary, NewData/binary>>,
    if
        byte_size(Data) < 20 ->
            {noreply, State#state{pkt_buf=Data}};
        true ->
            {noreply, handle_stream_data(Data, State)}
    end;

handle_info({tcp_closed, _Socket}, State=#state{chain=Chain}) ->
    log4erl:fatal(ebitcoin, "~p: Disconnected from peer!", [Chain]),
    {noreply, State};

handle_info({tcp_error, _Socket, Reason}, State=#state{chain=Chain}) ->
    log4erl:error(ebitcoin, "~p: Socket error: ~p", [Chain, Reason]),
    {noreply, State};

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

handle_bitcoin(#btc_version{version=Version, start_height=TheirBlockNum}, State=#state{chain=Chain, last_block_num=OurBlockNum}) ->
    log4erl:info(ebitcoin, "~p: Peer version: ~b; Our block count: ~b; Peer block count: ~b", [Chain, Version, OurBlockNum, TheirBlockNum]),
    if
        TheirBlockNum > OurBlockNum ->
            gen_server:cast(self(), {resync, TheirBlockNum});
        true ->
            ok
    end,
    % Always send verack
    {reply, verack, State};

handle_bitcoin(Block=#btc_block{header=Header}, State=#state{chain=Chain}) ->
    % TODO: Verify the block
    BlockHash = btc_protocol:get_hash(Header),
    case ebitcoin_db:get_block_height(Chain, BlockHash) of
        {ok, BlockNum} ->
            log4erl:info(ebitcoin, "~p: Storing full block #~b", [Chain, BlockNum]),
            ebitcoin_db:store_block(Chain, BlockNum, Block);
        {error, _} ->
            log4erl:warn(ebitcoin, "~p: Could not store full block, header not found!", [Chain])
    end,
    {noreply, State};

handle_bitcoin(#btc_headers{long_headers=LongHeaders}, State=#state{chain=Chain, last_block_num=OldLastBlockNum, last_block_hash=OldLastBlockHash, resync_mode=R}) ->
    {LastBlockNum, LastBlockHash, _} = lists:foldl(
        fun
            (_, {LBN, LBH, true}) ->
                {LBN, LBH, true};
            ({Header, _}, {LBN, LBH, false}) ->
                #btc_header{hash_prev_block=HashPrevBlock} = Header,
                BlockNum = case LBH of
                    undefined ->
                        undefined;
                    HashPrevBlock ->
                        LBN + 1;
                    _ ->
                        log4erl:debug(ebitcoin, "~p: Searching for a prev block...", [Chain]),
                        case ebitcoin_db:get_block_height(Chain, HashPrevBlock) of
                            {ok, FoundBN} ->
                                log4erl:warn(ebitcoin, "~p: Branching detected! Difference: ~b block(s)", [Chain, LBN-FoundBN]),
                                ebitcoin_db:cut_branch(Chain, FoundBN + 1),
                                FoundBN + 1;
                            {error, _} ->
                                log4erl:error(ebitcoin, "~p: Received an orphan block in headers message!", [Chain]),
                                undefined
                        end
                end,
                case BlockNum of
                    undefined ->
                        {LBN, LBH, true};
                    _ ->
                        ebitcoin_db:store_header(Chain, BlockNum, Header),
                        {BlockNum, btc_protocol:get_hash(Header), false}
                end
        end,
        {OldLastBlockNum, OldLastBlockHash, false},
        LongHeaders
    ),
    StoredNow = LastBlockNum-OldLastBlockNum,
    NewR = case R of
        {Got, undefined, FinalBlock} ->
            case FinalBlock of
                LastBlockHash ->
                    log4erl:info(ebitcoin, "~p: Resync: Received final block header #~b", [Chain, LastBlockNum]),
                    ebitcoin_db:force_view_updates(Chain),
                    false;
                _ ->
                    log4erl:info(ebitcoin, "~p: Resync: Now at block header #~b - got ~b", [Chain, LastBlockNum, Got+StoredNow]),
                    gen_server:cast(self(), {resync, FinalBlock}),
                    {Got+StoredNow, undefined, FinalBlock}
            end;
        {Got, ToGo, _} when Got+StoredNow >= ToGo ->
            log4erl:info(ebitcoin, "~p: Resync: Received final block header #~b", [Chain, LastBlockNum]),
            ebitcoin_db:force_view_updates(Chain),
            false;
        {Got, ToGo, FinalBlock} ->
            log4erl:info(ebitcoin, "~p: Resync: Now at block header #~b - ~.2f%", [Chain, LastBlockNum, (Got+StoredNow) * 100.0 / ToGo]),
            gen_server:cast(self(), {resync, FinalBlock}),
            {Got+StoredNow, ToGo, FinalBlock};
        false ->
            log4erl:info(ebitcoin, "~p: Now at block header #~b", [Chain, LastBlockNum]),
            false
    end,
    {noreply, State#state{last_block_num=LastBlockNum, last_block_hash=LastBlockHash, resync_mode=NewR}};

handle_bitcoin(#btc_inv{inventory=Inv}, State=#state{chain=Chain, last_block_num=LastBlockNum, resync_mode=R}) ->
    BlockInvs = lists:foldl(
        fun
            (IV=#btc_inv_vect{type=msg_block}, Acc) ->
                [IV|Acc];
            (#btc_inv_vect{type=msg_tx}, Acc) ->
                Acc; % Ignore transactions for now
            (#btc_inv_vect{type=Type}, Acc) ->
                log4erl:warn(ebitcoin, "~p: Received unknown inv type \"~p\", skipping!", [Chain, Type]),
                Acc
        end,
        [],
        Inv
    ),
    case BlockInvs of
        [] ->
            {noreply, State};
        _ when R =:= false ->
            % If we got a blockchange, send getheaders in all cases
            log4erl:info(ebitcoin, "~p: Detected a potentially new block", [Chain]),
            {reply, make_getheaders(Chain, LastBlockNum), State};
        _ ->
            log4erl:info(ebitcoin, "~p: Ignored blockchange during resync", [Chain]),
            {noreply, State}
    end;

handle_bitcoin(#btc_addr{}, State) ->
    {noreply, State}; % Ignore addr messages

handle_bitcoin(Message, State=#state{chain=Chain}) ->
    log4erl:warn(ebitcoin, "~p: Unhandled message:~n~p", [Chain, Message]),
    {noreply, State}.

handle_stream_data(Data, State=#state{chain=Chain, socket=Socket}) ->
    case scan_msg(Chain, Data) of
        not_found ->
            State#state{pkt_buf = <<>>};
        {incomplete, IncData} ->
            State#state{pkt_buf = IncData};
        {found, verack, _, _, Tail} ->
            log4erl:info(ebitcoin, "~p: Peer accepted our version.", [Chain]),
            handle_stream_data(Tail, State);
        {found, ping, _, _, Tail} -> % Ping is ignored by specification
            handle_stream_data(Tail, State);
        {found, Command, Checksum, Payload, Tail} ->
            ChecksumOk = case Command of
                version ->
                    true;
                _ ->
                    <<_:28/bytes, CChecksum:32/unsigned-big>> = ecoinpool_hash:dsha256_hash(Payload),
                    Checksum =:= CChecksum
            end,
            if
                ChecksumOk ->
                    handle_stream_data(Tail, case decode_message(Command, Payload) of
                        {error, Reason} ->
                            log4erl:error(ebitcoin, "~p: Error while decoding a message:~n~p", [Chain, Reason]),
                            log4erl:debug(ebitcoin, "~p: Message data was:~n~p - ~s", [Chain, Command, ecoinpool_util:bin_to_hexbin(Payload)]),
                            State;
                        {Message, <<>>} ->
                            case handle_bitcoin(Message, State) of
                                {noreply, NewState} ->
                                    NewState;
                                {reply, ReplyMessage, NewState} ->
                                    {ReplyCommand, ReplyPayload} = encode_message(ReplyMessage),
                                    gen_tcp:send(Socket, pack_message(Chain, ReplyCommand, ReplyPayload)),
                                    NewState
                            end;
                        {_, Trailer} ->
                            log4erl:error(ebitcoin, "~p: Error while decoding a message:~n~b trailing byte(s) found", [Chain, byte_size(Trailer)]),
                            log4erl:debug(ebitcoin, "~p: Message data was:~n~p - ~s", [Chain, Command, ecoinpool_util:bin_to_hexbin(Payload)]),
                            State
                    end);
                true ->
                    log4erl:error(ebitcoin, "~p: Message checksum mismatch.", [Chain]),
                    log4erl:debug(ebitcoin, "~p: Message data was:~n~p - ~s", [Chain, Command, ecoinpool_util:bin_to_hexbin(Payload)]),
                    handle_stream_data(Tail, State)
            end
    end.

scan_msg(_, <<>>) ->
    not_found;

scan_msg(bitcoin, Data = <<249,190,180,217, Command:12/bytes, Length:32/little, T/binary>>) ->
    unpack_message(Data, Command, Length, T);
scan_msg(bitcoin, Data = <<249, _/binary>>) when byte_size(Data) < 20 ->
    {incomplete, Data};
scan_msg(bitcoin_testnet, Data = <<250,191,181,218, Command:12/bytes, Length:32/little, T/binary>>) ->
    unpack_message(Data, Command, Length, T);
scan_msg(bitcoin_testnet, Data = <<250, _/binary>>) when byte_size(Data) < 20 ->
    {incomplete, Data};

scan_msg(namecoin, Data = <<249,190,180,254, Command:12/bytes, Length:32/little, T/binary>>) ->
    unpack_message(Data, Command, Length, T);
scan_msg(namecoin, Data = <<249, _/binary>>) when byte_size(Data) < 20 ->
    {incomplete, Data};
scan_msg(namecoin_testnet, Data = <<250,191,181,254, Command:12/bytes, Length:32/little, T/binary>>) ->
    unpack_message(Data, Command, Length, T);
scan_msg(namecoin_testnet, Data = <<250, _/binary>>) when byte_size(Data) < 20 ->
    {incomplete, Data};

% Fall through clause: Cut off one byte and try to find the next magic value
scan_msg(Chain, <<_, T/binary>>) ->
    log4erl:warn(ebitcoin, "Bitcoin data stream out of sync!"),
    scan_msg(Chain, T).

unpack_message(_, <<"version",0,0,0,0,0>>, Length, PayloadWithTail) when byte_size(PayloadWithTail) >= Length ->
    <<Payload:Length/bytes, Tail/binary>> = PayloadWithTail,
    {found, version, undefined, Payload, Tail};
unpack_message(_, <<"verack",0,0,0,0,0,0>>, Length, PayloadWithTail) when byte_size(PayloadWithTail) >= Length ->
    <<Payload:Length/bytes, Tail/binary>> = PayloadWithTail,
    {found, verack, undefined, Payload, Tail};
unpack_message(_, BCommand, Length, ChecksumPayloadWithTail) when byte_size(ChecksumPayloadWithTail) >= Length+4 ->
    Command = btc_protocol:decode_command(BCommand),
    <<Checksum:32/unsigned-little, Payload:Length/bytes, Tail/binary>> = ChecksumPayloadWithTail,
    {found, Command, Checksum, Payload, Tail};
unpack_message(Data, _, _, _) ->
    {incomplete, Data}.

pack_message(Chain, Message) ->
    {Command, Payload} = encode_message(Message),
    pack_message(Chain, Command, Payload).

pack_message(Chain, verack, _) ->
    Magic = network_magic(Chain),
    <<Magic/binary, "verack",0,0,0,0,0,0, 0:32>>;
pack_message(Chain, version, Payload) ->
    Magic = network_magic(Chain),
    Length = byte_size(Payload),
    <<Magic/binary, "version",0,0,0,0,0, Length:32/unsigned-little, Payload/bytes>>;
pack_message(Chain, Command, Payload) ->
    Magic = network_magic(Chain),
    BCommand = btc_protocol:encode_command(Command),
    Length = byte_size(Payload),
    <<_:28/bytes, Checksum:32/unsigned-big>> = ecoinpool_hash:dsha256_hash(Payload),
    <<Magic/binary, BCommand/binary, Length:32/unsigned-little, Checksum:32/unsigned-little, Payload/bytes>>.

decode_message(version, Data) ->
    btc_protocol:decode_version(Data);
decode_message(inv, Data) ->
    btc_protocol:decode_inv(Data);
decode_message(addr, Data) ->
    btc_protocol:decode_addr(Data);
decode_message(getdata, Data) ->
    btc_protocol:decode_getdata(Data);
decode_message(getblocks, Data) ->
    btc_protocol:decode_getblocks(Data);
decode_message(getheaders, Data) ->
    btc_protocol:decode_getheaders(Data);
decode_message(headers, Data) ->
    btc_protocol:decode_headers(Data);
decode_message(tx, Data) ->
    btc_protocol:decode_tx(Data);
decode_message(block, Data) ->
    btc_protocol:decode_block(Data);
decode_message(ping, _) ->
    ping;
decode_message(getaddr, _) ->
    getaddr;
decode_message(_, _) ->
    {error, unknown_message}.

encode_message(Message=#btc_version{}) ->
    {version, btc_protocol:encode_version(Message)};
encode_message(Message=#btc_inv{}) ->
    {inv, btc_protocol:encode_inv(Message)};
encode_message(Message=#btc_addr{}) ->
    {addr, btc_protocol:encode_addr(Message)};
encode_message(Message=#btc_getdata{}) ->
    {getdata, btc_protocol:encode_getdata(Message)};
encode_message(Message=#btc_getblocks{}) ->
    {getblocks, btc_protocol:encode_getblocks(Message)};
encode_message(Message=#btc_getheaders{}) ->
    {getheaders, btc_protocol:encode_getheaders(Message)};
encode_message(Message=#btc_headers{}) ->
    {headers, btc_protocol:encode_headers(Message)};
encode_message(Message=#btc_tx{}) ->
    {tx, btc_protocol:encode_tx(Message)};
encode_message(Message=#btc_block{}) ->
    {block, btc_protocol:encode_block(Message)};
encode_message(ping) ->
    {ping, <<>>};
encode_message(getaddr) ->
    {getaddr, <<>>};
encode_message(verack) ->
    {verack, <<>>}.

network_magic(bitcoin) ->
    <<249,190,180,217>>;
network_magic(bitcoin_testnet) ->
    <<250,191,181,218>>;
network_magic(namecoin) ->
    <<249,190,180,254>>;
network_magic(namecoin_testnet) ->
    <<250,191,181,254>>.

make_getheaders(Chain, BlockNum) ->
    BLH = ebitcoin_db:get_block_locator_hashes(Chain, BlockNum),
    %log4erl:debug(ebitcoin, "~p: Block locator object size: ~b", [Chain, length(BLH)]),
    #btc_getheaders{
        version = 50000,
        block_locator_hashes = BLH,
        hash_stop = binary:list_to_bin(lists:duplicate(32,0))
    }.
