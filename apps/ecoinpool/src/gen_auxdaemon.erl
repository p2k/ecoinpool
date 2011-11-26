
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

-module(gen_auxdaemon).

-export([behaviour_info/1]).

behaviour_info(callbacks) ->
    [
        % start_link(SubpoolId, Config)
        %   Starts the Aux CoinDaemon. Config is a property list.
        %   Should return {ok, PID} for later reference or an error.
        {start_link, 2},
        
        % get_aux_work(PID)
        %   Should return an auxwork record or {error, Message} on any error.
        {get_aux_work, 1},
        
        % send_aux_pow(PID, AuxHash, AuxPOW)
        %   Sends in a (single) aux proof-of-work to the Aux CoinDaemon.
        %   Should return one of the atoms "accepted", "rejected" or a tuple
        %   {error, Message} on any error.
        {send_aux_pow, 3}
    ];

behaviour_info(_Other) ->
    undefined.
