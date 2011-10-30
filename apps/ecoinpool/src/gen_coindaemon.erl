
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
        
        % share_target()
        %   Should return the target which satisfies a share as 256 bit binary
        %   in big endian.
        {share_target, 0},
        
        % get_workunit(PID)
        %   Get an unassigned workunit now. Also check for a new block.
        %   Should return {ok, Workunit} or {newblock, Workunit} or {error, Message}
        {get_workunit, 1},
        
        % encode_workunit(Workunit)
        %   Encodes a workunit so it can be sent as result to a getwork call.
        %   Should return a ejson-encodeable object.
        {encode_workunit, 1},
        
        % analyze_result(Result)
        %   Should return a list of tuples {WorkunitId, Hash, BData} from result
        %   data (i.e. the params part of the sendwork request). If an error
        %   occurs on any work item, the atom "error" should be returned instead
        %   of the list which will result in an invalid_request error.
        %   The hash should be in big-endian binary format. BData is the block
        %   header data in binary format to be sent later with send_result and
        %   also to be stored in the shares database.
        %   This is used to identify and check the result against the target.
        %   For daemons which don't support multi-results, this should always
        %   return a list with a single item.
        {analyze_result, 1},
        
        % make_reply(Items)
        %   Should return a reply suitable to announce that work was accepted or
        %   rejected a ejson-encodable object. Items is a list of (binary)
        %   hashes and/or the atom "invalid"; for daemons which don't support
        %   multi-results, Items always contains a single item.
        {make_reply, 1},
        
        % send_result(PID, BData)
        %   Sends in a (single) result to the CoinDaemon.
        %   Should return one of the atoms "accepted", "rejected" or a tuple
        %   {error, Message} on any error.
        {send_result, 2}
    ];

behaviour_info(_Other) ->
    undefined.
