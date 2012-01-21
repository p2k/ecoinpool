
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

-module(gen_sharelogger).

-export([behaviour_info/1]).

behaviour_info(callbacks) ->
    [
        % start_link(LoggerId, Config)
        %   Starts the ShareLogger. LoggerId is an atom which should be used to
        %   register the share logger locally. Config is a property list.
        %   Should return {ok, PID} for later reference or an error.
        {start_link, 2},
        
        % log_share(LoggerId, Share)
        %   Should asynchronously log the share. It may be a normal or remote
        %   share. The logger has to take care of any caching and crash safety.
        %   Also all uncommitted shares must be sent out on termination, so
        %   make sure you trap exits - you got 15 seconds at maximum.
        {log_share, 2}
    ];

behaviour_info(_Other) ->
    undefined.
