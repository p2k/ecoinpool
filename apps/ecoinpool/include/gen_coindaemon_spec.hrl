
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

-include("ecoinpool_misc_types.hrl").

-spec start_link(SubpoolId :: binary(), Config :: [conf_property()]) ->
    {ok, pid()} | ignore | {error, {already_started, pid()} | term()}.

-spec getwork_method() ->
    atom().

-spec sendwork_method() ->
    atom().

-spec share_target() ->
    binary().

-spec encode_workunit(Workunit :: workunit()) ->
    term().

-spec analyze_result(Result :: [term()]) ->
    [{WorkunitId :: binary(), Hash :: binary(), BData :: binary()}] | error.

-spec make_reply(Items :: [binary() | invalid]) ->
    term().

-ifdef(COINDAEMON_SUPPORTS_MM).
    -spec set_mmm(PID :: pid(), MMM :: mmm()) ->
        ok.
-else.
    -spec set_mmm(PID :: pid(), MMM :: mmm()) ->
        {error, binary()}.
-endif.

-spec post_workunit(PID :: pid()) ->
    ok.

-spec send_result(PID :: pid(), BData :: binary()) ->
    accepted | rejected | {error, binary()}.

-ifdef(COINDAEMON_SUPPORTS_MM).
    -spec get_first_tx_with_branches(PID :: pid(), Workunit :: workunit()) ->
        {ok, FirstTransaction :: any(), MerkleTreeBranches :: [binary()]}.
-else.
    -spec get_first_tx_with_branches(PID :: pid(), Workunit :: workunit()) ->
        {error, binary()}.
-endif.
