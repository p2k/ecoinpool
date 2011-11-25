
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

% This abstract module acts as a wrapper for gen_auxdaemon modules. As such, it
% allows easier handling of auxdaemons within the server module.

% Instances of this module are returned by ecoinpool_server_sup:start_auxdaemon/3

-module(abstract_auxdaemon, [M, PID]).

-export([get_aux_block/0, send_aux_pow/2]).

-export([coindaemon_mfargs/0, auxdaemon_module/0]).

get_aux_block() ->
    M:get_aux_block(PID).

send_aux_pow(AuxHash, AuxPOW) ->
    M:send_aux_pow(PID, AuxHash, AuxPOW).

coindaemon_mfargs() ->
    {M, get_aux_block, [PID]}.

auxdaemon_module() ->
    M.
