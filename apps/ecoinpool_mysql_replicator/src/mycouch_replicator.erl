
%%
%% mycouch_replicator - A CouchDB and MySQL replication engine
%%
%% Copyright (C) 2011  Patrick "p2k" Schneider <patrick.p2k.schneider@gmail.com>
%%
%% This program is free software: you can redistribute it and/or modify
%% it under the terms of the GNU General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% This program is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU General Public License for more details.
%%
%% You should have received a copy of the GNU General Public License
%% along with this program.  If not, see <http://www.gnu.org/licenses/>.
%%

-module(mycouch_replicator).
-behaviour(gen_changes).

-include_lib("mysql/include/mysql.hrl").

-export([start_link/8]).

-export([init/1, handle_change/2, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(queries, {
    changes,
    rev,
    couch_id,
    upd_rev,
    ins_rev,
    del_rev,
    data,
    del
}).

% Internal state record
-record(state, {
    couch_db,
    
    my_pool_id,
    my_table,
    my_id_field,
    my_timer,
    
    my_queries,
    
    couch_to_my,
    my_to_couch,
    
    cancel_echo
}).

-define(Log(F, P), io:format("~p:~b: " ++ F ++ "~n", [?MODULE, ?LINE] ++ P)).

%% ===================================================================
%% API functions
%% ===================================================================

% Notes:
% - CouchFilter can be used to set a filter for the changes monitor, it can
%   either be a single string FilterName or a tuple {FilterName, FilterArgs} or
%   undefined to disable filtering.
% - MyTriggerFields should be a list of strings or binaries with fields to be
%   checked for changes. Set it to undefined to react to any change.
% - MyInterval is in seconds.
% - The primary key for the MySQL table must be INT and AUTO INCREMENT.
% - CouchDB ID fields have to be strings, MySQL ID fields have to be integers.
% - Both CouchToMy and MyToCouch must be functions which take one property list
%   as parameter and return one (possibly converted) property list as result.
% - The keys of the property lists coming from MySQL will be converted to lower
%   case strings prior to the call to MyToCouch; property lists for CouchDB,
%   on the other hand, have binaries as their keys in all cases.
start_link(CouchDb, CouchFilter, MyPoolId, MyTable, MyTriggerFields, MyInterval, CouchToMy, MyToCouch) ->
    InitParams = [CouchDb, MyPoolId, MyTable, MyTriggerFields, MyInterval, CouchToMy, MyToCouch],
    if
        MyInterval < 1 -> error(interval_less_than_one);
        true -> ok
    end,
    case CouchFilter of
        undefined ->
            gen_changes:start_link(?MODULE, CouchDb, [continuous, heartbeat], InitParams);
        {FilterName, FilterArgs} ->
            gen_changes:start_link(?MODULE, CouchDb, [continuous, heartbeat, {filter, FilterName, FilterArgs}], InitParams);
        FilterName ->
            gen_changes:start_link(?MODULE, CouchDb, [continuous, heartbeat, {filter, FilterName}], InitParams)
    end.

%% ===================================================================
%% Gen_Changes callbacks
%% ===================================================================

init([CouchDb, MyPoolId, MyTable, MyTriggerFields, MyInterval, CouchToMy, MyToCouch]) ->
    % Trap exit
    process_flag(trap_exit, true),
    % Get the MySQL ID field name
    {data, MyIdFieldResult} = mysql:fetch(MyPoolId, ["SHOW COLUMNS FROM `", MyTable, "` WHERE `Key` = 'PRI';"]),
    MyIdField = case mysql:get_result_rows(MyIdFieldResult) of
        [{FName, _Type, _Null, _Key, _Default, <<"auto_increment">>}] -> FName;
        _ -> error(no_auto_increment_primary_key)
    end,
    % Check if the revision table exists
    {data, RevCheckResult} = mysql:fetch(MyPoolId, ["SHOW TABLES LIKE '", MyTable, "_rev';"]),
    case mysql:get_result_rows(RevCheckResult) of
        [] -> % Not found -> create
            {updated, _} = mysql:fetch(MyPoolId, [
                "CREATE TABLE `", MyTable, "_rev` (",
                "`my_id` INT NOT NULL, ",
                "`couch_id` VARCHAR(255) NOT NULL, ",
                "`rev` VARCHAR(255) NULL, ",
                "`changed` TINYINT(1) NOT NULL DEFAULT 1, ",
                "`deleted` TINYINT(1) NOT NULL DEFAULT 0, ",
                "PRIMARY KEY (`my_id`), ",
                "UNIQUE INDEX `couch_id_UNIQUE` (`couch_id`));"
            ]),
            % Initially create new records in the revision table
            {updated, _} = mysql:fetch(MyPoolId, [
                "INSERT INTO `", MyTable, "_rev` (`my_id`, `couch_id`) SELECT `", MyIdField, "`, REPLACE(UUID(), '-', '') FROM `", MyTable, "`;"
            ]);
        _ ->
            ok
    end,
    % Check if the all the triggers exist, create if missing
    {data, TriggerCheckResult} = mysql:fetch(MyPoolId, ["SHOW TRIGGERS LIKE '", MyTable, "';"]),
    ExistingTriggers = lists:map(fun (Row) -> element(1, Row) end, mysql:get_result_rows(TriggerCheckResult)),
    MissingTriggers = [<<"rev_on_insert">>, <<"rev_on_update">>, <<"rev_on_delete">>] -- ExistingTriggers,
    lists:foreach(
        fun
            (<<"rev_on_insert">>) ->
                {updated, _} = mysql:fetch(MyPoolId, [
                    "CREATE TRIGGER `rev_on_insert` AFTER INSERT ON `", MyTable, "` FOR EACH ROW ",
                    "INSERT INTO `", MyTable, "_rev` (`my_id`, `couch_id`) VALUES (NEW.`", MyIdField, "`, REPLACE(UUID(), '-', ''));"
                ]);
            (<<"rev_on_update">>) when MyTriggerFields =:= [] ->
                {updated, _} = mysql:fetch(MyPoolId, [
                    "CREATE TRIGGER `rev_on_update` AFTER UPDATE ON `", MyTable, "` FOR EACH ROW ",
                    case MyTriggerFields of
                        undefined ->
                            "";
                        _ ->
                            ["BEGIN\n  IF NOT (", string:join([["OLD.`", F, "` <=> NEW.`", F, "`"] || F <- MyTriggerFields], " AND "), ") THEN\n    "]
                    end,
                    "UPDATE `", MyTable, "_rev` SET `changed` = 1 WHERE `my_id` = NEW.`", MyIdField, "`;",
                    case MyTriggerFields of
                        undefined -> "";
                        _ -> "\n  END IF;\nEND;"
                    end
                ]);
            (<<"rev_on_delete">>) ->
                {updated, _} = mysql:fetch(MyPoolId, [
                    "CREATE TRIGGER `rev_on_delete` AFTER DELETE ON `", MyTable, "` FOR EACH ROW ",
                    "UPDATE `", MyTable, "_rev` SET `deleted` = 1 WHERE `my_id` = OLD.`", MyIdField, "`;"
                ]);
            _ -> ok
        end,
        MissingTriggers
    ),
    
    % Prepare queries
    ChangesQ = list_to_atom(lists:concat([MyTable, "_changes_q"])),
    mysql:prepare(ChangesQ, iolist_to_binary(["SELECT `my_id`, `couch_id`, `rev`, `deleted` FROM `", MyTable, "_rev` WHERE `changed` = 1 OR `deleted` = 1;"])),
    RevQ = list_to_atom(lists:concat([MyTable, "_rev_q"])),
    mysql:prepare(RevQ, iolist_to_binary(["SELECT `my_id`, `rev`, `deleted` FROM `", MyTable, "_rev` WHERE `couch_id` = ?;"])),
    CouchIdQ = list_to_atom(lists:concat([MyTable, "_couch_id_q"])),
    mysql:prepare(CouchIdQ, iolist_to_binary(["SELECT `couch_id` FROM `", MyTable, "_rev` WHERE `my_id` = ?;"])),
    UpdRevQ = list_to_atom(lists:concat([MyTable, "_upd_rev_q"])),
    mysql:prepare(UpdRevQ, iolist_to_binary(["UPDATE `", MyTable, "_rev` SET `rev` = ?, `changed` = 0 WHERE `my_id` = ?;"])),
    InsRevQ = list_to_atom(lists:concat([MyTable, "_ins_rev_q"])),
    mysql:prepare(InsRevQ, iolist_to_binary(["UPDATE `", MyTable, "_rev` SET `couch_id` = ?, `rev` = ?, `changed` = 0 WHERE `my_id` = ?;"])),
    DataQ = list_to_atom(lists:concat([MyTable, "_data_q"])),
    mysql:prepare(DataQ, iolist_to_binary(["SELECT * FROM `", MyTable, "` WHERE `", MyIdField, "` = ?;"])),
    DelQ = list_to_atom(lists:concat([MyTable, "_del_q"])),
    mysql:prepare(DelQ, iolist_to_binary(["DELETE FROM `pool_worker` WHERE `", MyIdField, "` = ?;"])),
    DelRevQ = list_to_atom(lists:concat([MyTable, "_del_rev_q"])),
    mysql:prepare(DelRevQ, <<"DELETE FROM `pool_worker_rev` WHERE `my_id` = ?;">>),
    
    MyQueries = #queries{changes=ChangesQ, rev=RevQ, couch_id=CouchIdQ, upd_rev=UpdRevQ, ins_rev=InsRevQ, del_rev=DelRevQ, data=DataQ, del=DelQ},
    
    % Schedule changes polling timer
    {ok, MyTimer} = timer:send_interval(MyInterval * 1000, check_my_changes),
    
    {ok, #state{
        couch_db = CouchDb,
        my_pool_id = MyPoolId,
        my_table = MyTable,
        my_id_field = MyIdField,
        my_timer = MyTimer,
        my_queries = MyQueries,
        couch_to_my = CouchToMy,
        my_to_couch = MyToCouch,
        cancel_echo = queue:new()
    }}.

handle_change({ChangeProps}, State=#state{couch_db=CouchDb, my_pool_id=MyPoolId, my_table=MyTable, my_id_field=MyIdField, my_queries=MyQueries, couch_to_my=CouchToMy, cancel_echo=CancelEcho}) ->
    CouchId = proplists:get_value(<<"id">>, ChangeProps),
    case queue:peek(CancelEcho) of
        {value, CouchId} ->
            ?Log("CouchId ~s: Echo cancelled.", [CouchId]),
            {noreply, State#state{cancel_echo=queue:drop(CancelEcho)}};
        _ ->
            
            [{[{<<"rev">>, Rev}]}] = proplists:get_value(<<"changes">>, ChangeProps),
            Deleted = proplists:get_value(<<"deleted">>, ChangeProps, false),
            
            {data, MyRevData} = mysql:execute(MyPoolId, MyQueries#queries.rev, [CouchId]),
            case mysql:get_result_rows(MyRevData) of
                [] ->
                    if
                        Deleted -> % Gone is gone...
                            ok;
                        true -> % Missing -> insert
                            ?Log("CouchId ~s: Inserting.", [CouchId]),
                            insert_into_mysql(CouchDb, CouchId, Rev, MyPoolId, MyTable, MyQueries, CouchToMy)
                    end;
                [{MyId, MyRev, MyDeleted}] ->
                    if
                        Deleted -> % Document deleted -> delete regardless of conflicts
                            ?Log("CouchId ~s: MyId ~b: Deleting.", [CouchId, MyId]),
                            delete_from_mysql(MyPoolId, MyId, MyQueries);
                        MyDeleted =:= 1 -> % Row marked as deleted -> do nothing here
                            ?Log("CouchId ~s: MyId ~b: Marked for deletion.", [CouchId, MyId]),
                            ok;
                        MyRev =:= Rev -> % On same revision (and maybe changed) -> do nothing here
                            ?Log("CouchId ~s: MyId ~b: On same revision.", [CouchId, MyId]),
                            ok;
                        true -> % Not on same revision (and maybe conflicting) -> take precedence and update
                            ?Log("CouchId ~s: MyId ~b: Updating.", [CouchId, MyId]),
                            update_mysql(CouchDb, CouchId, Rev, MyPoolId, MyTable, MyIdField, MyId, MyQueries, CouchToMy)
                    end
            end,
            
            {noreply, State}
    end.

handle_my_change(MyPoolId, CouchDb, MyId, CouchId, MyRev, Deleted, MyQueries, MyToCouch) ->
    case couchbeam:lookup_doc_rev(CouchDb, CouchId) of
        {error, _} ->
            if
                Deleted -> % Gone is gone...
                    ?Log("MyId ~b: Gone is gone.", [MyId]),
                    delete_from_mysql(MyPoolId, MyId, MyQueries),
                    false;
                true -> % Missing -> insert
                    ?Log("MyId ~b: Inserting.", [MyId]),
                    insert_into_couchdb(MyPoolId, MyId, CouchDb, MyQueries, MyToCouch),
                    true
            end;
        Rev ->
            if
                Deleted -> % Document deleted -> delete regardless of conflicts
                    ?Log("MyId ~b: CouchId ~s: Deleting.", [MyId, CouchId]),
                    delete_from_couchdb(CouchDb, CouchId, MyPoolId, MyId, MyQueries),
                    true;
                true -> % Document changed -> update regardless of conflicts
                    if
                        Rev =:= MyRev -> ?Log("MyId ~b: CouchId ~s: Updating.", [MyId, CouchId]);
                        true -> ?Log("MyId ~b: CouchId ~s: Overriding conflict.", [MyId, CouchId])
                    end,
                    update_couchdb(MyPoolId, MyId, CouchDb, CouchId, Rev, MyQueries, MyToCouch)
            end
    end.

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(check_my_changes, State=#state{couch_db=CouchDb, my_pool_id=MyPoolId, my_queries=MyQueries, my_to_couch=MyToCouch, cancel_echo=CancelEcho}) ->
    % Query for changes
    {data, MyChangesData} = mysql:execute(MyPoolId, MyQueries#queries.changes, []),
    case mysql:get_result_rows(MyChangesData) of
        [] -> % No changes
            {noreply, State};
        MyChanges ->
            {noreply, State#state{cancel_echo = lists:foldl(
                fun ({MyId, CouchId, MyRev, Deleted}, CancelEchoAcc) ->
                    case handle_my_change(MyPoolId, CouchDb, MyId, CouchId, MyRev, Deleted =:= 1, MyQueries, MyToCouch) of
                        true -> queue:in(CouchId, CancelEchoAcc);
                        false -> CancelEchoAcc
                    end
                end,
                CancelEcho,
                MyChanges
            )}}
    end;

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{my_timer=MyTimer, my_queries=MyQueries}) ->
    [_|Names] = tuple_to_list(MyQueries),
    lists:foreach(fun mysql:unprepare/1, Names),
    timer:cancel(MyTimer),
    ok.

% -----

insert_into_mysql(CouchDb, CouchId, Rev, MyPoolId, MyTable, #queries{ins_rev=InsRevQ}, CouchToMy) ->
    % Retrieve CouchDB document
    {ok, {DocProps}} = couchbeam:open_doc(CouchDb, CouchId),
    % Convert
    MyProps = CouchToMy(DocProps),
    % Create INSERT statement
    {MyKeys, MyValues} = lists:unzip([{[$`, Key ,$`], mysql:encode(Value)} || {Key, Value} <- MyProps]),
    % Insert data
    {updated, #mysql_result{insertid=MyId}} = mysql:fetch(MyPoolId, ["INSERT INTO `", MyTable, "` (", string:join(MyKeys, ", "), ") VALUES (", string:join(MyValues, ", "), ");"]),
    % Update the new rev entry (created through the trigger)
    {updated, _} = mysql:execute(MyPoolId, InsRevQ, [CouchId, Rev, MyId]),
    ok.

update_mysql(CouchDb, CouchId, Rev, MyPoolId, MyTable, MyIdField, MyId, #queries{upd_rev=UpdRevQ, data=DataQ}, CouchToMy) ->
    % Retrieve CouchDB document
    {ok, {DocProps}} = couchbeam:open_doc(CouchDb, CouchId),
    % Convert
    NewMyProps = CouchToMy(DocProps),
    % Retrieve MySQL row
    OldMyProps = get_mysql_row_props(MyPoolId, MyId, DataQ),
    % Find changes
    case find_changes(OldMyProps, NewMyProps) of
        [] ->
            ok; % No changes -> skip update
        Changes ->
            % Create UPDATE statement
            Updates = lists:map(fun ({Key, Value}) -> [$`, Key, "` = ", mysql:encode(Value)] end, Changes),
            % Update data
            {updated, _} = mysql:fetch(MyPoolId, ["UPDATE `", MyTable, "` SET ", string:join(Updates, ", "), " WHERE `", MyIdField, "` = ", integer_to_list(MyId), $;])
    end,
    % Update the rev entry
    {updated, _} = mysql:execute(MyPoolId, UpdRevQ, [Rev, MyId]),
    ok.

delete_from_mysql(MyPoolId, MyId, #queries{del_rev=DelRevQ, del=DelQ}) ->
    % Delete the row
    {updated, _} = mysql:execute(MyPoolId, DelQ, [MyId]),
    % Delete the rev entry
    {updated, _} = mysql:execute(MyPoolId, DelRevQ, [MyId]),
    ok.

insert_into_couchdb(MyPoolId, MyId, CouchDb, #queries{couch_id=CouchIdQ, upd_rev=UpdRevQ, data=DataQ}, MyToCouch) ->
    % Get the new document ID provided by MySQL's UUID()
    {data, CouchIdResult} = mysql:execute(MyPoolId, CouchIdQ, [MyId]),
    [{CouchId}] = mysql:get_result_rows(CouchIdResult),
    % Retrieve MySQL row
    MyProps = get_mysql_row_props(MyPoolId, MyId, DataQ),
    % Convert
    DocProps = filter_undefined(MyToCouch(MyProps)),
    % Save new document and get rev
    {ok, {DocPropsSaved}} = couchbeam:save_doc(CouchDb, {[{<<"_id">>, CouchId} | DocProps]}),
    Rev = proplists:get_value(<<"_rev">>, DocPropsSaved),
    % Update the rev entry
    {updated, _} = mysql:execute(MyPoolId, UpdRevQ, [Rev, MyId]),
    ok.

update_couchdb(MyPoolId, MyId, CouchDb, CouchId, Rev, #queries{upd_rev=UpdRevQ, data=DataQ}, MyToCouch) ->
    % Retrieve MySQL row
    MyProps = get_mysql_row_props(MyPoolId, MyId, DataQ),
    % Convert
    NewDocProps = lists:keysort(1, MyToCouch(MyProps)),
    % Retrieve CouchDB document
    {ok, {OldDocPropsUnsorted}} = couchbeam:open_doc(CouchDb, CouchId),
    OldDocProps = lists:keysort(1, OldDocPropsUnsorted),
    % Find changes
    NewRev = case find_changes(OldDocProps, NewDocProps) of
        [] ->
            Rev; % No changes -> skip update
        Changes ->
            % Merge changes
            DocPropsUpdated = filter_undefined(lists:ukeymerge(1, Changes, OldDocProps)),
            % Update data
            {ok, {DocPropsSaved}} = couchbeam:save_doc(CouchDb, {DocPropsUpdated}),
            proplists:get_value(<<"_rev">>, DocPropsSaved)
    end,
    % Update the rev entry
    {updated, _} = mysql:execute(MyPoolId, UpdRevQ, [NewRev, MyId]),
    NewRev =/= Rev.

delete_from_couchdb(CouchDb, CouchId, MyPoolId, MyId, #queries{del_rev=DelRevQ}) ->
    % Retrieve CouchDB document
    {ok, Doc} = couchbeam:open_doc(CouchDb, CouchId),
    % Delete it
    couchbeam:delete_doc(CouchDb, Doc),
    % Delete the rev entry
    {updated, _} = mysql:execute(MyPoolId, DelRevQ, [MyId]),
    ok.

get_mysql_row_props(MyPoolId, MyId, DataQ) ->
    {data, Result} = mysql:execute(MyPoolId, DataQ, [MyId]),
    [ResultRow] = mysql:get_result_rows(Result),
    FieldNames = [string:to_lower(binary_to_list(FieldName)) || {_, FieldName, _, _} <- mysql:get_result_field_info(Result)],
    lists:zip(FieldNames, tuple_to_list(ResultRow)).

find_changes(PListOld, PListNew) ->
    lists:filter(
        fun ({Key, NewValue}) ->
            NewValue =/= proplists:get_value(Key, PListOld)
        end,
        PListNew
    ).

filter_undefined(PList) ->
    lists:filter(fun ({_, undefined}) -> false; (_) -> true end, PList).
