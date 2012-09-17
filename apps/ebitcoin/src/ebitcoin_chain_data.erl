
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

-module(ebitcoin_chain_data).

-include("btc_protocol_records.hrl").

-export([
    type_and_port/1,
    network_magic/1,
    genesis_block/1
]).

type_and_port(<<"btc">>) -> {bitcoin, 8333};
type_and_port(<<"btc_testnet">>) -> {bitcoin_testnet, 18333};
type_and_port(<<"nmc">>) -> {namecoin, 8334};
type_and_port(<<"nmc_testnet">>) -> {namecoin_testnet, 18334};
type_and_port(<<"ltc">>) -> {litecoin, 9333};
type_and_port(<<"ltc_testnet">>) -> {litecoin_testnet, 19333};
type_and_port(<<"frc">>) -> {freicoin, 8639};
type_and_port(<<"frc_testnet">>) -> {freicoin_testnet, 18639};

type_and_port(_) -> undefined.

network_magic(bitcoin) ->
    <<249,190,180,217>>;
network_magic(bitcoin_testnet) ->
    <<250,191,181,218>>;
network_magic(namecoin) ->
    <<249,190,180,254>>;
network_magic(namecoin_testnet) ->
    <<250,191,181,254>>;
network_magic(litecoin) ->
    <<251,192,182,219>>;
network_magic(litecoin_testnet) ->
    <<252,193,183,220>>;
network_magic(freicoin) ->
    <<199,211,35,137>>;
network_magic(freicoin_testnet) ->
    <<200,212,36,138>>;

network_magic(_) -> undefined.

genesis_block(bitcoin) ->
    ZeroHash = binary:list_to_bin(lists:duplicate(32,0)),
    Header = #btc_header{
        version = 1,
        hash_prev_block = ZeroHash,
        hash_merkle_root = base64:decode(<<"Sl4eS6q4nzoyUYqIwxvIf2GPdmc+LMd6shJ7ev3tozs=">>),
        timestamp = 16#495fab29,
        bits = 16#1d00ffff,
        nonce = 16#7c2bac1d
    },
    Tx = #btc_tx{
        version = 1,
        tx_in = [#btc_tx_in{
            prev_output_hash = ZeroHash,
            prev_output_index = 16#ffffffff,
            signature_script = [16#1d00ffff, <<4>>, <<"The Times 03/Jan/2009 Chancellor on brink of second bailout for banks">>],
            sequence = 16#ffffffff
        }],
        tx_out = [#btc_tx_out{
            value = 5000000000,
            pk_script = base64:decode(<<"QQRniv2w/lVIJxln8aZxMLcQXNaoKOA5CaZ5YuDqH2Hetkn2vD9M7zjE81UE5R7BEt5cOE33uguNV4pMcCtr8R1frA==">>)
        }],
        lock_time = 0
    },
    BlockHash = <<"000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f">>,
    {BlockHash, Header, Tx};

genesis_block(namecoin) ->
    ZeroHash = binary:list_to_bin(lists:duplicate(32,0)),
    Header = #btc_header{
        version = 1,
        hash_prev_block = ZeroHash,
        hash_merkle_root = base64:decode(<<"QcYtvZBoyJpElSXjzVrGGyDs4ow8OLPzWyFh8ObTyw0=">>),
        timestamp = 16#4daa33c1,
        bits = 16#1c007fff,
        nonce = 16#a21ea192
    },
    Tx = #btc_tx{
        version = 1,
        tx_in = [#btc_tx_in{
            prev_output_hash = ZeroHash,
            prev_output_index = 16#ffffffff,
            signature_script = [16#1c007fff, 522, <<"... choose what comes next.  Lives of your own, or a return to chains. -- V">>],
            sequence = 16#ffffffff
        }],
        tx_out = [#btc_tx_out{
            value = 5000000000,
            pk_script = base64:decode(<<"QQS2IDaQUM2Jn/u8To7lHoxFNKhVu0Y0OdY9I11HeWhdi29IcKI4zzZayU+hPvmioizZnQ1e6G3K\nvK/ONses9DzlrA==">>)
        }],
        lock_time = 0
    },
    BlockHash = <<"000000000062b72c5e2ceb45fbc8587e807c155b0da735e6483dfba2f0a9c770">>,
    {BlockHash, Header, Tx};

genesis_block(litecoin) ->
    ZeroHash = binary:list_to_bin(lists:duplicate(32,0)),
    Header = #btc_header{
        version = 1,
        hash_prev_block = ZeroHash,
        hash_merkle_root = base64:decode(<<"l937uua+l/1s3z58oTIyo6//I1Pim636t/cwEe3Uztk=">>),
        timestamp = 16#4e8eaab9,
        bits = 16#1d00ffff,
        nonce = 16#7c3f51cd
    },
    Tx = #btc_tx{
        version = 1,
        tx_in = [#btc_tx_in{
            prev_output_hash = ZeroHash,
            prev_output_index = 16#ffffffff,
            signature_script = [16#1d00ffff, <<4>>, <<"NY Times 05/Oct/2011 Steve Jobs, Apple", 226, 128, 153, "s Visionary, Dies at 56">>],
            sequence = 16#ffffffff
        }],
        tx_out = [#btc_tx_out{
            value = 5000000000,
            pk_script = base64:decode(<<"QQQBhHEPpomtUCNpDIDzpJyPE/jUW4yFf7y8i8So5NPrSxD01GBPoI3OYBqvD0cCFv4bUYULSs8hsXnEUHCsewOprA==">>)
        }],
        lock_time = 0
    },
    BlockHash = <<"12a765e31ffd4059bada1e25190f6e98c99d9714d334efa41a195a7e7e04bfe2">>,
    {BlockHash, Header, Tx};

genesis_block(freicoin) ->
    ZeroHash = binary:list_to_bin(lists:duplicate(32,0)),
    Header = #btc_header{
        version = 1,
        hash_prev_block = ZeroHash,
        hash_merkle_root = base64:decode(<<"tgN4/8leZxiafMA6JQwtK5IyLyLQY/Ya1KexQ5+r5D8=">>),
        timestamp = 16#50536290,
        bits = 16#1d00ffff,
        nonce = 16#37fc17e7
    },
    Tx = #btc_tx{
        version = 2,
        tx_in = [#btc_tx_in{
            prev_output_hash = ZeroHash,
            prev_output_index = 16#ffffffff,
            signature_script = [16#1d00ffff, <<4>>, <<"Telegraph 27/Jun/2012 Barclays hit with ", 194, 163, "290m fine over Libor fixing">>],
            sequence = 16#ffffffff
        }],
        tx_out = [#btc_tx_out{
            value = 7950387546951,
            pk_script = base64:decode(<<"QQRniv2w/lVIJxln8aZxMLcQXNaoKOA5CaZ5YuDqH2Hetkn2vD9M7zjE81UE5R7BEt5cOE33uguNV4pMcCtr8R1frA==">>)
        }],
        lock_time = 0,
        ref_height = 0
    },
    BlockHash = <<"000000000c29f26697c30e29039927ab4241b5fc2cc76db7e0dafa5e2612ad46">>,
    {BlockHash, Header, Tx}.
