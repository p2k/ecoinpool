
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

% ecoinpool merged mining manager

% This abstract module acts as a manager for one or more gen_auxdaemon modules.
% As such, it allows easier handling of merged mining within the server module.

% Instances of this module are returned by ecoinpool_server_sup:add_auxdaemon/4
% and ecoinpool_server_sup:remove_auxdaemon/3

-module(ecoinpool_mmm, [AuxDaemons]).

-include("btc_protocol_records.hrl").
-include("ecoinpool_workunit.hrl").

-export([get_new_aux_work/1, send_aux_pow/5]).

-export([update_aux_daemon/2, add_aux_daemon/2, remove_aux_daemon/1, aux_daemon_modules/0]).

get_new_aux_work(OldAuxWork) ->
    % This code will change if multi aux chains are supported
    [{Module, PID}] = AuxDaemons,
    
    AuxWork = Module:get_aux_work(PID),
    
    if
        AuxWork =:= OldAuxWork ->
            no_new_aux_work;
        true ->
            AuxWork
    end.

send_aux_pow(#auxwork{aux_hash=AuxHash}, CoinbaseTx, BlockHash, TxTreeBranches, ParentHeader) ->
    % This code will change if multi aux chains are supported
    [{Module, PID}] = AuxDaemons,
    
    AuxPOW = #btc_auxpow{
        coinbase_tx = CoinbaseTx,
        block_hash = ecoinpool_util:byte_reverse(BlockHash),
        tx_tree_branches = TxTreeBranches,
        parent_header = ParentHeader
    },
    Module:send_aux_pow(PID, AuxHash, AuxPOW).

% The following code is for future multi aux chain support

update_aux_daemon(Module, PID) ->
    Pair = {Module, PID},
    case lists:member(Pair, AuxDaemons) of
        true -> unchanged;
        _ -> ecoinpool_mmm:new(lists:keyreplace(Module, 1, AuxDaemons, Pair))
    end.

add_aux_daemon(Module, PID) ->
    ecoinpool_mmm:new([{Module, PID} | AuxDaemons]).

remove_aux_daemon(Module) ->
    case proplists:delete(Module, AuxDaemons) of
        [] ->
            undefined;
        NewAuxDaemons ->
            ecoinpool_mmm:new(NewAuxDaemons)
    end.

aux_daemon_modules() ->
    lists:map(fun ({Module, _}) -> Module end, AuxDaemons).
