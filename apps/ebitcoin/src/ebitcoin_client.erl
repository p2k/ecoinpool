
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
    start_link/3,
    getdata_single/3
]).

% Callbacks from gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    name,
    node_nonce,
    peer_host,
    peer_port,
    socket,
    
    pkt_buf
}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(Name, PeerHost, PeerPort) when Name =:= bitcoin; Name =:= bitcoin_testnet; Name =:= namecoin; Name =:= namecoin_testnet ->
    gen_server:start_link({local, Name}, ?MODULE, [Name, PeerHost, PeerPort], []).

getdata_single(Name, Type, Hash) ->
    gen_server:cast(Name, {getdata_single, Name, Type, Hash}).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([Name, PeerHost, PeerPort]) ->
    % Trap exit
    process_flag(trap_exit, true),
    % Setup the chain database
    ok = ebitcoin_db:setup_chain_db(Name),
    % Connect
    log4erl:warn(ebitcoin, "~p: Connecting to ~s:~b...", [Name, PeerHost, PeerPort]),
    Socket = case gen_tcp:connect(PeerHost, PeerPort, [binary, inet, {packet, raw}]) of
        {ok, S} ->
            log4erl:warn(ebitcoin, "~p: Connection established.", [Name]),
            S;
        {error, Reason} ->
            log4erl:fatal(ebitcoin, "~p: Could not connect!", [Name]),
            error(Reason)
    end,
    gen_server:cast(Name, start_handshake),
    {ok, #state{name=Name, node_nonce=crypto:rand_uniform(0, 16#10000000000000000), peer_host=PeerHost, peer_port=PeerPort, socket=Socket, pkt_buf = <<>>}}.

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast(start_handshake, State=#state{name=Name, node_nonce=NodeNonce, socket=Socket}) ->
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
        start_height = 0
    },
    gen_tcp:send(Socket, pack_message(Name, Version)),
    {noreply, State};

handle_cast({getdata_single, Name, Type, BSHash}, State=#state{name=Name, socket=Socket}) ->
    Getdata = #btc_getdata{inventory=[#btc_inv_vect{type=Type, hash=ecoinpool_util:hexbin_to_bin(BSHash)}]},
    gen_tcp:send(Socket, pack_message(Name, Getdata)),
    {noreply, State};

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

handle_info({tcp_closed, _Socket}, State=#state{name=Name}) ->
    log4erl:fatal(ebitcoin, "~p: Disconnected from peer!", [Name]),
    {noreply, State};

handle_info({tcp_error, _Socket, Reason}, State=#state{name=Name}) ->
    log4erl:error(ebitcoin, "~p: Socket error: ~p", [Name, Reason]),
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

handle_bitcoin(#btc_version{}, State) ->
    % Just send verack, no matter what
    {reply, verack, State};

handle_bitcoin(Block=#btc_block{}, State=#state{name=Name}) ->
    % TODO: Verify the block
    ebitcoin_db:store_block(Name, 0, Block),
    {noreply, State};

handle_bitcoin(Message, State=#state{name=Name}) ->
    log4erl:warn(ebitcoin, "~p: Unhandled message:~n~p", [Name, Message]),
    {noreply, State}.

handle_stream_data(Data, State=#state{name=Name, socket=Socket}) ->
    case scan_msg(Name, Data) of
        not_found ->
            State#state{pkt_buf = <<>>};
        {incomplete, IncData} ->
            State#state{pkt_buf = IncData};
        {found, verack, _, _, Tail} ->
            log4erl:info(ebitcoin, "~p: Peer accepted our version.", [Name]),
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
                            log4erl:error(ebitcoin, "~p: Error while decoding a message:~n~p", [Name, Reason]),
                            log4erl:debug(ebitcoin, "~p: Message data was:~n~p - ~s", [Name, Command, ecoinpool_util:bin_to_hexbin(Payload)]),
                            State;
                        Message ->
                            case handle_bitcoin(Message, State) of
                                {noreply, NewState} ->
                                    NewState;
                                {reply, ReplyMessage, NewState} ->
                                    {ReplyCommand, ReplyPayload} = encode_message(ReplyMessage),
                                    gen_tcp:send(Socket, pack_message(Name, ReplyCommand, ReplyPayload)),
                                    NewState
                            end
                    end);
                true ->
                    log4erl:error(ebitcoin, "~p: Message checksum mismatch.", [Name]),
                    log4erl:debug(ebitcoin, "~p: Message data was:~n~p - ~s", [Name, Command, ecoinpool_util:bin_to_hexbin(Payload)]),
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
scan_msg(Name, <<_, T/binary>>) ->
    log4erl:warn(ebitcoin, "Bitcoin data stream out of sync!"),
    scan_msg(Name, T).

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

pack_message(Name, Message) ->
    {Command, Payload} = encode_message(Message),
    pack_message(Name, Command, Payload).

pack_message(Name, verack, _) ->
    Magic = network_magic(Name),
    <<Magic/binary, "verack",0,0,0,0,0,0, 0:32>>;
pack_message(Name, version, Payload) ->
    Magic = network_magic(Name),
    Length = byte_size(Payload),
    <<Magic/binary, "version",0,0,0,0,0, Length:32/unsigned-little, Payload/bytes>>;
pack_message(Name, Command, Payload) ->
    Magic = network_magic(Name),
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
decode_message(tx, Data) ->
    {Tx, <<>>} = btc_protocol:decode_tx(Data), Tx;
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
