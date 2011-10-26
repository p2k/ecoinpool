
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

-module(gen_coindaemon).

-export([behaviour_info/1]).

behaviour_info(callbacks) ->
    [
        % start_link(SubpoolId, Config)
        %   Starts the CoinDaemon. Config is a property list.
        %   Should return {ok, PID} for later reference or an error.
        {start_link, 2},
        % getwork_method()
        %   Should return an atom which is the name of the only valid getwork
        %   method (static); this is typically getwork for bitcoin networks and
        %   sc_getwork for solidcoin networks.
        {getwork_method, 0},
        % sendwork_method()
        %   Should return an atom which is the name of the method which is used
        %   to return shares (static); this is typically getwork for bitcoin
        %   networks and sc_testwork for solidcoin networks.
        {sendwork_method, 0},
        % get_workunit(PID)
        %   Get an unassigned workunit now. Also check for a new block.
        %   Should return {ok, Workunit} or {newblock, Workunit} or {error, Message}
        {get_workunit, 1},
        % encode_workunit(Workunit)
        %   Encodes a workunit so it can be sent as result to a getwork call.
        %   Should return a ejson-encodeable object.
        {encode_workunit, 1}
    ];

behaviour_info(_Other) ->
    undefined.
