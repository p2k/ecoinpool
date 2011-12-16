
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

-record(btc_header, {
    version = 1 :: integer(),
    hash_prev_block :: binary(),
    hash_merkle_root :: binary(),
    timestamp :: integer(),
    bits :: integer(),
    nonce = 0 :: integer(),
    auxpow :: btc_auxpow() | undefined
}).
-type btc_header() :: #btc_header{}.

-record(btc_tx_in, {
    prev_output_hash :: binary(),
    prev_output_index :: integer(),
    signature_script :: binary() | [term()],
    sequence = 16#ffffffff :: integer()
}).
-type btc_tx_in() :: #btc_tx_in{}.

-record(btc_tx_out, {
    value :: integer(),
    pk_script :: binary() | [term()]
}).
-type btc_tx_out() :: #btc_tx_out{}.

-record(btc_tx, {
    version = 1 :: integer(),
    tx_in :: [btc_tx_in()],
    tx_out :: [btc_tx_out()],
    lock_time = 0 :: integer()
}).
-type btc_tx() :: #btc_tx{}.

-record(btc_auxpow, {
    coinbase_tx :: btc_tx() | binary(),
    block_hash :: binary(),
    tx_tree_branches :: [binary()],
    tx_index = 0 :: integer(),
    aux_tree_branches = [] :: [binary()],
    aux_index = 0 :: integer(),
    parent_header :: btc_header() | binary()
}).
-type btc_auxpow() :: #btc_auxpow{}.

-record(btc_block, {
    header :: btc_header(),
    txns :: [btc_tx()]
}).
-type btc_block() :: #btc_block{}.

-record(btc_net_addr, {
    time :: integer() | undefined,
    services :: integer(),
    ip :: {ip4 | ip6, string()} | inet:ip_address(),
    port :: integer()
}).
-type btc_net_addr() :: #btc_net_addr{}.

-record(btc_addr, {
    addr_list :: [btc_net_addr()]
}).
-type btc_addr() :: #btc_addr{}.

-record(btc_version, {
    version :: integer(),
    services :: integer(),
    timestamp :: integer(),
    addr_recv :: btc_net_addr(),
    addr_from :: btc_net_addr(),
    nonce :: integer(),
    sub_version_num :: binary(),
    start_height :: integer()
}).
-type btc_version() :: #btc_version{}.

-record(btc_inv_vect, {
    type :: error | msg_tx | msg_block | integer(),
    hash :: binary()
}).
-type btc_inv_vect() :: #btc_inv_vect{}.

-record(btc_inv, {
    inventory :: [btc_inv_vect()]
}).
-type btc_inv() :: #btc_inv{}.

-record(btc_getdata, {
    inventory :: [btc_inv_vect()]
}).
-type btc_getdata() :: #btc_getdata{}.

-record(btc_getblocks, {
    version :: integer(),
    block_locator_hashes :: [binary()],
    hash_stop :: binary()
}).
-type btc_getblocks() :: #btc_getblocks{}.

-record(btc_getheaders, {
    version :: integer(),
    block_locator_hashes :: [binary()],
    hash_stop :: binary()
}).
-type btc_getheaders() :: #btc_getheaders{}.

-record(btc_headers, {
    long_headers :: [{btc_header(), integer()}]
}).
-type btc_headers() :: #btc_headers{}.
