
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

-include("ebitcoin_db_records.hrl").
-include("btc_protocol_records.hrl").

-export([
    start_link/1,
    reload_config/1,
    last_block_num/1,
    load_full_block/2,
    add_blockchange_listener/2,
    remove_blockchange_listener/2
]).

% Callbacks from gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    client,
    net_magic,
    node_nonce,
    socket,
    
    bc_listeners,
    
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

start_link(ClientId) ->
    gen_server:start_link({global, {?MODULE, ClientId}}, ?MODULE, [ClientId], []).

reload_config(Client=#client{id=ClientId}) ->
    gen_server:cast({global, {?MODULE, ClientId}}, {reload_config, Client}).

last_block_num(ClientId) ->
    gen_server:call({global, {?MODULE, ClientId}}, last_block_num).

-spec load_full_block(ClientId :: binary(), BlockHashOrHeight :: binary() | integer()) -> loading | already | unknown.
load_full_block(ClientId, BlockHashOrHeight) ->
    gen_server:call({global, {?MODULE, ClientId}}, {load_full_block, BlockHashOrHeight}).

% Note: This will callback gen_server:cast(ListenerRef, {ebitcoin_blockchange, ClientId, BlockHash, BlockNum}) on a blockchange
% Also, the listener will be monitored and automatically removed if it goes down.
add_blockchange_listener(ClientId, ListenerRef) ->
    gen_server:cast({global, {?MODULE, ClientId}}, {add_blockchange_listener, ListenerRef}).

remove_blockchange_listener(ClientId, ListenerRef) ->
    gen_server:cast({global, {?MODULE, ClientId}}, {remove_blockchange_listener, ListenerRef}).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([ClientId]) ->
    % Trap exit
    process_flag(trap_exit, true),
    % Get Subpool record; terminate on error
    {ok, Client} = ebitcoin_db:get_client_record(ClientId),
    % Schedule config reload
    gen_server:cast(self(), {reload_config, Client}),
    % Recover from crash
    BCListeners = case ebitcoin_sup:crash_fetch(ClientId) of
        error ->
            [];
        {ok, Value} ->
            log4erl:info(ebitcoin, "~s: Recovered ~b listener(s) from the crash repo", [ClientId, length(Value)]),
            [{ListenerRef, erlang:monitor(process, ListenerRef)} || ListenerRef <- Value]
    end,
    {ok, #state{client = #client{}, node_nonce = crypto:rand_uniform(0, 16#10000000000000000), bc_listeners = BCListeners}}.

handle_call(last_block_num, _From, State=#state{last_block_num=LastBlockNum}) ->
    {reply, LastBlockNum, State};

handle_call({load_full_block, BlockHashOrHeight}, _From, State=#state{client=Client}) ->
    case ebitcoin_db:get_block_info(Client, BlockHashOrHeight) of
        error ->
            {reply, unknown, State};
        {_, _, true} ->
            {reply, already, State};
        {_, BlockHash, false} ->
            Getdata = #btc_getdata{
                inventory=[#btc_inv_vect{
                    type=msg_block,
                    hash=BlockHash
                }]
            },
            send_msg(State, Getdata),
            {reply, loading, State}
    end;

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast({reload_config, Client}, State=#state{client=OldClient, socket=OldSocket, bc_listeners=BCListeners, last_block_num=OldBlockNum, last_block_hash=OldBlockHash, pkt_buf=OldPKTBuf}) ->
    % Extract config
    #client{id=ClientId, name=Name, chain=Chain, host=Host, port=Port} = Client,
    #client{host=OldHost, port=OldPort} = OldClient,
    
    % Setup the client databases
    ok = ebitcoin_db:setup_client_dbs(Client),
    % Get last block information
    {BlockNum, BlockHash} = ebitcoin_db:get_last_block_info(Client),
    
    % Disconnect?
    Connect = if
        OldHost =:= Host, OldPort =:= Port -> false;
        OldSocket =:= undefined -> true;
        true -> gen_tcp:close(OldSocket), true
    end,
    % Connect?
    {Socket, PKTBuf} = if
        Connect -> {do_connect(Name, Host, Port), <<>>};
        true -> {OldSocket, OldPKTBuf}
    end,
    
    % Blockchange through database?
    if
        OldBlockNum =/= BlockNum, OldBlockHash =/= BlockHash ->
            broadcast_blockchange(BCListeners, ClientId, BlockHash, BlockNum);
        true ->
            ok
    end,
    
    % Get the network magic bytes
    NetMagic = ebitcoin_chain_data:network_magic(Chain),
    
    {noreply, State#state{client=Client, net_magic=NetMagic, socket=Socket, last_block_num=BlockNum, last_block_hash=BlockHash, pkt_buf=PKTBuf}};

handle_cast(start_handshake, State=#state{node_nonce=NodeNonce, socket=Socket, last_block_num=BlockNum}) ->
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
    send_msg(State, Version),
    {noreply, State};

handle_cast({resync, FinalBlock}, State=#state{client=Client, last_block_num=BlockNum, resync_mode=R}) ->
    #client{name=Name} = Client,
    NewR = case R of
        {_, _, FinalBlock} ->
            log4erl:info(ebitcoin, "~s: Resync: Requesting next blocks...", [Name]),
            R;
        _ ->
            if
                is_binary(FinalBlock) ->
                    log4erl:warn(ebitcoin, "~s: Entering resync mode...", [Name]),
                    {0, undefined, FinalBlock};
                is_integer(FinalBlock) ->
                    log4erl:warn(ebitcoin, "~s: Entering resync mode, getting ~b block(s)...", [Name, FinalBlock-BlockNum]),
                    {0, FinalBlock-BlockNum, FinalBlock}
            end
    end,
    send_msg(State, make_getheaders(Client, BlockNum)),
    {noreply, State#state{resync_mode=NewR}};

handle_cast({add_blockchange_listener, ListenerRef}, State=#state{client=#client{name=Name}, bc_listeners=BCListeners}) ->
    case proplists:is_defined(ListenerRef, BCListeners) of
        true ->
            {noreply, State};
        false ->
            log4erl:info(ebitcoin, "~s: Adding blockchange listener: ~p", [Name, ListenerRef]),
            ListenerMRef = erlang:monitor(process, ListenerRef),
            {noreply, State#state{bc_listeners=[{ListenerRef, ListenerMRef} | BCListeners]}}
    end;

handle_cast({remove_blockchange_listener, ListenerRef}, State=#state{client=#client{name=Name}, bc_listeners=BCListeners}) ->
    case proplists:lookup(ListenerRef, BCListeners) of
        none ->
            log4erl:warn(ebitcoin, "~s: Could not remove blockchange listener: ~p", [Name, ListenerRef]),
            {noreply, State};
        {_, ListenerMRef} ->
            log4erl:info(ebitcoin, "~s: Removing blockchange listener: ~p", [Name, ListenerRef]),
            erlang:demonitor(ListenerMRef, [flush]),
            {noreply, State#state{bc_listeners=proplists:delete(ListenerRef, BCListeners)}}
    end;

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

handle_info({tcp_closed, _Socket}, State=#state{client=#client{name=Name, host=Host, port=Port}, socket=OldSocket}) ->
    log4erl:warn(ebitcoin, "~s: Disconnected from peer!", [Name]),
    gen_tcp:close(OldSocket),
    Socket = do_connect(Name, Host, Port),
    {noreply, State#state{socket=Socket}};

handle_info({tcp_error, _Socket, Reason}, State=#state{client=#client{name=Name}}) ->
    log4erl:error(ebitcoin, "~s: Socket error: ~p", [Name, Reason]),
    {noreply, State};

handle_info({'DOWN', _, _, ListenerRef, _}, State=#state{client=#client{name=Name}, bc_listeners=BCListeners}) ->
    log4erl:info(ebitcoin, "~s: Removing blockchange listener: ~p", [Name, ListenerRef]),
    {noreply, State#state{bc_listeners=proplists:delete(ListenerRef, BCListeners)}};

handle_info(_Message, State) ->
    {noreply, State}.

terminate(normal, _) ->
    ok;
terminate(shutdown, _) ->
    ok;
terminate({shutdown, _}, _) ->
    ok;
terminate(_, #state{bc_listeners=[]}) ->
    ok;
terminate(_Reason, #state{client=#client{id=ClientId, name=Name}, bc_listeners=BCListeners}) ->
    log4erl:error(ebitcoin, "~s: Storing ~b listener(s) in the crash repo", [Name, length(BCListeners)]),
    ebitcoin_sup:crash_store(ClientId, [ListenerRef || {ListenerRef, _} <- BCListeners]),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

-spec handle_bitcoin(Message :: term(), State :: #state{}) -> {reply, term(), State :: #state{}} | {noreply, State :: #state{}}.
handle_bitcoin(#btc_version{version=Version, start_height=TheirBlockNum}, State=#state{client=#client{name=Name}, last_block_num=OurBlockNum}) ->
    log4erl:info(ebitcoin, "~s: Peer version: ~b; Our block count: ~b; Peer block count: ~b", [Name, Version, OurBlockNum, TheirBlockNum]),
    if
        TheirBlockNum > OurBlockNum ->
            gen_server:cast(self(), {resync, TheirBlockNum});
        true ->
            ok
    end,
    % Always send verack
    {reply, verack, State};

handle_bitcoin(Block=#btc_block{header=Header}, State=#state{client=Client}) ->
    #client{name=Name} = Client,
    % TODO: Verify the block
    BlockHash = btc_protocol:get_hash(Header),
    case ebitcoin_db:get_block_height(Client, BlockHash) of
        {ok, BlockNum} ->
            log4erl:info(ebitcoin, "~s: Storing full block #~b", [Name, BlockNum]),
            ebitcoin_db:store_block(Client, BlockNum, Block);
        {error, _} ->
            log4erl:warn(ebitcoin, "~s: Could not store full block, header not found!", [Name])
    end,
    {noreply, State};

handle_bitcoin(#btc_headers{long_headers=LongHeaders}, State=#state{client=Client, bc_listeners=BCListeners, last_block_num=OldLastBlockNum, last_block_hash=OldLastBlockHash, resync_mode=R}) ->
    #client{id=ClientId, name=Name} = Client,
    {LastBlockNum, LastBlockHash} = case LongHeaders of
        [] ->
            {OldLastBlockNum, OldLastBlockHash};
        [{Header, _} | _] -> % Check the first
            #btc_header{hash_prev_block=HashPrevBlock} = Header,
            StartBlockNum = case OldLastBlockHash of
                undefined ->
                    undefined;
                HashPrevBlock ->
                    OldLastBlockNum + 1;
                _ ->
                    log4erl:debug(ebitcoin, "~s: Searching for a prev block...", [Name]),
                    case ebitcoin_db:get_block_height(Client, HashPrevBlock) of
                        {ok, FoundBN} ->
                            log4erl:warn(ebitcoin, "~s: Branching detected! Difference: ~b block(s)", [Name, OldLastBlockNum-FoundBN]),
                            ebitcoin_db:cut_branch(Client, FoundBN + 1),
                            FoundBN + 1;
                        {error, _} ->
                            log4erl:error(ebitcoin, "~s: Received an orphan block in headers message!", [Name]),
                            undefined
                    end
            end,
            case StartBlockNum of
                undefined ->
                    {OldLastBlockNum, OldLastBlockHash};
                _ ->
                    Result = lists:foldl(
                        fun
                            ({H=#btc_header{hash_prev_block=LBH}, _}, {BN, LBH, Acc}) ->
                                TBH = btc_protocol:get_hash(H),
                                {BN + 1, TBH, Acc ++ [{BN, TBH, H}]};
                            (_, _) ->
                                cancel
                        end,
                        {StartBlockNum, HashPrevBlock, []},
                        LongHeaders
                    ),
                    case Result of
                        cancel ->
                            log4erl:error(ebitcoin, "~s: Received headers are not consecutive!", [Name]),
                            {OldLastBlockNum, OldLastBlockHash};
                        {LBN, LBH, PreparedHeaders} ->
                            ebitcoin_db:store_headers(Client, PreparedHeaders),
                            {LBN-1, LBH}
                    end
            end
    end,
    StoredNow = LastBlockNum-OldLastBlockNum,
    NewR = case R of
        {Got, undefined, FinalBlock} ->
            case FinalBlock of
                LastBlockHash ->
                    log4erl:warn(ebitcoin, "~s: Resync: Received final block header #~b", [Name, LastBlockNum]),
                    broadcast_blockchange(BCListeners, ClientId, LastBlockHash, LastBlockNum),
                    ebitcoin_db:force_view_updates(Client),
                    false;
                _ ->
                    log4erl:info(ebitcoin, "~s: Resync: Now at block header #~b - got ~b", [Name, LastBlockNum, Got+StoredNow]),
                    gen_server:cast(self(), {resync, FinalBlock}),
                    {Got+StoredNow, undefined, FinalBlock}
            end;
        {Got, ToGo, _} when Got+StoredNow >= ToGo ->
            log4erl:warn(ebitcoin, "~s: Resync: Received final block header #~b", [Name, LastBlockNum]),
            broadcast_blockchange(BCListeners, ClientId, LastBlockHash, LastBlockNum),
            ebitcoin_db:force_view_updates(Client),
            false;
        {Got, ToGo, FinalBlock} ->
            log4erl:info(ebitcoin, "~s: Resync: Now at block header #~b - ~.2f%", [Name, LastBlockNum, (Got+StoredNow) * 100.0 / ToGo]),
            gen_server:cast(self(), {resync, FinalBlock}),
            {Got+StoredNow, ToGo, FinalBlock};
        false ->
            broadcast_blockchange(BCListeners, ClientId, LastBlockHash, LastBlockNum),
            log4erl:info(ebitcoin, "~s: Now at block header #~b", [Name, LastBlockNum]),
            false
    end,
    {noreply, State#state{last_block_num=LastBlockNum, last_block_hash=LastBlockHash, resync_mode=NewR}};

handle_bitcoin(#btc_inv{inventory=Inv}, State=#state{client=Client, last_block_num=LastBlockNum, resync_mode=R}) ->
    #client{name=Name} = Client,
    BlockInvs = lists:foldl(
        fun
            (IV=#btc_inv_vect{type=msg_block}, Acc) ->
                [IV|Acc];
            (#btc_inv_vect{type=msg_tx}, Acc) ->
                Acc; % Ignore transactions for now
            (#btc_inv_vect{type=Type}, Acc) ->
                log4erl:warn(ebitcoin, "~s: Received unknown inv type \"~p\", skipping!", [Name, Type]),
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
            log4erl:info(ebitcoin, "~s: Detected a potentially new block", [Name]),
            {reply, make_getheaders(Client, LastBlockNum), State};
        _ ->
            log4erl:info(ebitcoin, "~s: Ignored blockchange during resync", [Name]),
            {noreply, State}
    end;

handle_bitcoin(#btc_addr{}, State) ->
    {noreply, State}; % Ignore addr messages

handle_bitcoin(Message, State=#state{client=#client{name=Name}}) ->
    log4erl:warn(ebitcoin, "~s: Unhandled message:~n~p", [Name, Message]),
    {noreply, State}.

do_connect(Name, Host, Port) ->
    log4erl:warn(ebitcoin, "~s: Connecting to ~s:~b...", [Name, Host, Port]),
    case gen_tcp:connect(binary:bin_to_list(Host), Port, [binary, inet, {packet, raw}]) of
        {ok, S} ->
            log4erl:warn(ebitcoin, "~s: Connection established.", [Name]),
            gen_server:cast(self(), start_handshake),
            S;
        {error, Reason} ->
            log4erl:fatal(ebitcoin, "~s: Could not connect!", [Name]),
            error(Reason)
    end.

handle_stream_data(Data, State=#state{client=#client{name=Name}, net_magic=NetMagic}) ->
    case scan_msg(NetMagic, Data) of
        not_found ->
            State#state{pkt_buf = <<>>};
        {incomplete, IncData} ->
            State#state{pkt_buf = IncData};
        {found, verack, _, _, Tail} ->
            log4erl:info(ebitcoin, "~s: Peer accepted our version.", [Name]),
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
                            log4erl:error(ebitcoin, "~s: Error while decoding a message:~n~p", [Name, Reason]),
                            log4erl:debug(ebitcoin, "~s: Message data was:~n~p - ~s", [Name, Command, ecoinpool_util:bin_to_hexbin(Payload)]),
                            State;
                        {Message, <<>>} ->
                            case handle_bitcoin(Message, State) of
                                {noreply, NewState} ->
                                    NewState;
                                {reply, ReplyMessage, NewState} ->
                                    send_msg(NewState, ReplyMessage),
                                    NewState
                            end;
                        {_, Trailer} ->
                            log4erl:error(ebitcoin, "~s: Error while decoding a message:~n~b trailing byte(s) found", [Name, byte_size(Trailer)]),
                            log4erl:debug(ebitcoin, "~s: Message data was:~n~p - ~s", [Name, Command, ecoinpool_util:bin_to_hexbin(Payload)]),
                            State
                    end);
                true ->
                    log4erl:error(ebitcoin, "~s: Message checksum mismatch.", [Name]),
                    log4erl:debug(ebitcoin, "~s: Message data was:~n~p - ~s", [Name, Command, ecoinpool_util:bin_to_hexbin(Payload)]),
                    handle_stream_data(Tail, State)
            end
    end.

send_msg(#state{net_magic=NetMagic, socket=Socket}, Message) ->
    {Command, Payload} = encode_message(Message),
    gen_tcp:send(Socket, pack_message(NetMagic, Command, Payload)).

scan_msg(_, <<>>) ->
    not_found;

scan_msg(<<M1,M2,M3,M4>>, Data = <<M1,M2,M3,M4, Command:12/bytes, Length:32/little, T/binary>>) ->
    unpack_message(Data, Command, Length, T);
scan_msg(<<M1,_,_,_>>, Data = <<M1, _/binary>>) when byte_size(Data) < 20 ->
    {incomplete, Data};

% Fall through clause: Cut off one byte and try to find the next magic value
scan_msg(NetMagic, <<_, T/binary>>) ->
    log4erl:warn(ebitcoin, "Bitcoin data stream out of sync!"),
    scan_msg(NetMagic, T).

unpack_message(_, BCommand, Length, ChecksumPayloadWithTail) when byte_size(ChecksumPayloadWithTail) >= Length+4 ->
    Command = btc_protocol:decode_command(BCommand),
    <<Checksum:32/unsigned-little, Payload:Length/bytes, Tail/binary>> = ChecksumPayloadWithTail,
    {found, Command, Checksum, Payload, Tail};
unpack_message(Data, _, _, _) ->
    {incomplete, Data}.

pack_message(NetMagic, Command, Payload) ->
    BCommand = btc_protocol:encode_command(Command),
    Length = byte_size(Payload),
    <<_:28/bytes, Checksum:32/unsigned-big>> = ecoinpool_hash:dsha256_hash(Payload),
    <<NetMagic/binary, BCommand/binary, Length:32/unsigned-little, Checksum:32/unsigned-little, Payload/bytes>>.

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
%encode_message(Message=#btc_inv{}) ->
%    {inv, btc_protocol:encode_inv(Message)};
%encode_message(Message=#btc_addr{}) ->
%    {addr, btc_protocol:encode_addr(Message)};
encode_message(Message=#btc_getdata{}) ->
    {getdata, btc_protocol:encode_getdata(Message)};
%encode_message(Message=#btc_getblocks{}) ->
%    {getblocks, btc_protocol:encode_getblocks(Message)};
encode_message(Message=#btc_getheaders{}) ->
    {getheaders, btc_protocol:encode_getheaders(Message)};
%encode_message(Message=#btc_headers{}) ->
%    {headers, btc_protocol:encode_headers(Message)};
%encode_message(Message=#btc_tx{}) ->
%    {tx, btc_protocol:encode_tx(Message)};
%encode_message(Message=#btc_block{}) ->
%    {block, btc_protocol:encode_block(Message)};
%encode_message(ping) ->
%    {ping, <<>>};
%encode_message(getaddr) ->
%    {getaddr, <<>>};
encode_message(verack) ->
    {verack, <<>>}.

make_getheaders(Client, BlockNum) ->
    BLH = ebitcoin_db:get_block_locator_hashes(Client, BlockNum),
    %log4erl:debug(ebitcoin, "~s: Block locator object size: ~b", [Client#client.name, length(BLH)]),
    #btc_getheaders{
        version = 50000,
        block_locator_hashes = BLH,
        hash_stop = binary:list_to_bin(lists:duplicate(32,0))
    }.

broadcast_blockchange([], _, _, _) ->
    ok;
broadcast_blockchange(BCListeners, ClientId, BlockHash, BlockNum) ->
    lists:foreach(fun ({ListenerRef, _}) -> gen_server:cast(ListenerRef, {ebitcoin_blockchange, ClientId, BlockHash, BlockNum}) end, BCListeners).
