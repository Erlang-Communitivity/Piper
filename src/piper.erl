%% ``The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved via the world wide web at http://www.erlang.org/EPLICENSE.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% The Initial Developer of the Original Code is Bill Barnhill.
%% Portions created by Bill Barnhill are Copyright 2012, Bill 
%% Barnhill. All Rights Reserved.''
%% 

%%%-------------------------------------------------------------------
%%% @author Bill Barnhill <>
%%% @copyright (C) 2012, Bill Barnhill
%%% @doc
%%%
%%% @end
%%% Created : 15 Jan 2012 by Bill Barnhill <>
%%%-------------------------------------------------------------------
-module(piper).

-behaviour(gen_server).

%% API
-export([
	 start_link/0, 
	 pipe/2, 
	 config/1,
	 add_gather/3,
	 clear_routes/1,
	 set_route/2,
	 gen_server_cast_route/1,
	 gen_server_cast_route/2,
	 gen_server_call_route/2,
	 gen_server_call_route/3,
	 raw_messaging_route/1,
	 raw_messaging_route/2
	]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE). 

-record(state, {map,gathers, gather_index}).
-record(route, {dest_server, type, dest_label, generator}).
-record(gather,{name, queue_map, route}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc
%% Pipe a message to a label
%%
%% @spec pipe(Message, Label) -> ok 
%% @end
%%--------------------------------------------------------------------
%% dest_server, type, dest_label, generator
gen_server_cast_route(ServerSpec) ->
    gen_server_cast_route(ServerSpec, none).
gen_server_cast_route(ServerSpec, GeneratorFn) ->
    #route{dest_server=ServerSpec, type=cast, dest_label=none, generator=GeneratorFn}.

gen_server_call_route(ServerSpec, ToLabel) ->
    gen_server_call_route(ServerSpec, ToLabel, none).
gen_server_call_route(ServerSpec, ToLabel, GeneratorFn) ->
    #route{dest_server=ServerSpec, type=call, dest_label=ToLabel, generator=GeneratorFn}.

raw_messaging_route(Pid) ->
    raw_messaging_route(Pid, none).
raw_messaging_route(Pid, GeneratorFn) ->
    #route{dest_server=Pid, type=direct, dest_label=none, generator=GeneratorFn}.

pipe(Message, Label) ->
    gen_server:cast(piper, {self(), Message, Label}).

config(Cmd={add_gather, _GatherName, [_Label1 | [_Label2 | _EmpyOrMoreLabels]], #route{}}) ->
    send_config(Cmd);
config(Cmd={clear_route, _Label}) ->
    send_config(Cmd);
config(Cmd={set_route, _Label, #route{}}) ->
    send_config(Cmd);
config(Cmd={add_route, _Label, #route{}}) ->
    send_config(Cmd);
config(Cmd) ->
    {error, unrecognized_command, Cmd}.

add_gather(Name, Labels, Route=#route{}) ->
    send_config({add_gather, Name, Labels, Route}).

clear_routes(Label) ->
    config({clear_route, Label}).

set_route(Label, Route=#route{}) ->
    config({set_route, Label, Route}).

send_config(Cmd) ->
    gen_server:cast(piper, {self(), piper, Cmd}).
    

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    State = #state{map=rbdict:new(),gather_index=rbdict:new(),gathers=rbdict:new()}, 
    {ok, State};
init(ConfigCmds) ->
    State = #state{map=rbdict:new(),gather_index=rbdict:new(),gathers=rbdict:new()}, 
    {ok, lists:foldl(fun do_config/2, State, ConfigCmds)}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages, we do not do anything here. Everything is cast.
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% This is where commands are handled.
%% Each command alters the routing.
%%   Send label inputs to serverspec via gen_server:cast : {tap, Label, ServerSpec}
%%   Send label inputs to pid via ! operator : {raw_tap, Label, Pid}
%%   Send 
%%
%% A cooperator gen_server has handle cast signature that all are variations of
%%   handle_cast({From, Label, DestLabel, Msg}) 
%% The handle_cast, if it has any output should handle the output by calling
%%   piper:send(DestLabel
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({_From, piper, Cmd}, State) ->
    {noreply, do_config(Cmd, State)};
handle_cast({From, Label, MsgIn}, State=#state{map=SpecMap,gathers=Gathers,gather_index=GatherIndex}) ->
    Specs = dict:fetch(Label, SpecMap),
    PiperFn = make_piper_fn(From, Label, MsgIn),
    PiperErrors = lists:foldl(PiperFn, [], Specs),
    GathersForLabel = gathers_for_label(Label, Gathers, GatherIndex),
    case lists:foldr(fun gather_fold_fn/2, {From, MsgIn, Label, Gathers, PiperErrors}, GathersForLabel) of
	{From, MsgIn, Label, Gathers, []} -> {noreply, State#state{gathers=Gathers}};
	{From, MsgIn, Label, Gathers, Errors} -> {stop, {errors, Errors}, State#state{gathers=Gathers}}
    end.

do_config({add_route, Label, Route=#route{}}, State) ->
    Map1 = rbdict:append(Label, Route, State#state.map),
    State#state{map=Map1};
do_config({set_route, Label, Route=#route{}}, State) ->
    Map1 = rbdict:store(Label, Route, State#state.map),
    State#state{map=Map1};
do_config({clear_route, Label}, State) ->
    Map1 = rbdict:erase(Label, State#state.map),
    State#state{map=Map1};
do_config({add_gather, GatherName, [_L1 | [_L2 | _]]=Labels, Route=#route{}}, State) ->
    QueueMap = lists:foldl(fun (Label, Acc) -> rbdict:store(Label, queue:new(), Acc) end, rbdict:new(), Labels), 
    Gather = #gather{name=GatherName, queue_map=QueueMap, route=Route},
    Gathers = rbdict:store(GatherName, Gather),
    GatherIdx = lists:foldl(
		  fun (Label, Acc) -> rbdict:append(Label, GatherName, Acc) end, 
		  State#state.gather_index,
		  Labels),
    State#state{gather_index=GatherIdx,gathers=Gathers}.

gathers_for_label(Label, AllGathers, GatherIndex) ->
    %% Get GatherNames for Label from GatherIndex
    %% Get Gathers by mapping over GatherNames
    GatherNames = case rbdict:find(Label, GatherIndex) of 
		      {ok, Value} -> Value;
		      _ -> []
		  end,
    lists:map(
      fun (GatherName) -> rbdict:fetch(GatherName, AllGathers) end,
      GatherNames).

gather_fold_fn(Gather=#gather{name=Name, route=Route}, {From, MsgIn, Label, Gathers, Errors}) ->
    Gather1 = gather_enqueue_msg(Gather, Label, MsgIn),
    Gathers1 = rbdict:store(Name, Gather1, Gathers),
    case gather_is_ready(Gather1) of
	true ->
	    {ok, MsgOut, Gather2} = gather_gen_args(Gather1),
	    PiperFn = make_piper_fn(From, Label, MsgOut),
	    Gathers2 = rbdict:store(Name, Gather2, Gathers1),
	    {From, Label, Gathers2, PiperFn(Route, Errors)};
	_ -> {From, MsgIn, Label, Gathers1, Errors}
    end.

gather_enqueue_msg(Gather=#gather{queue_map=QueueMap}, Label, MsgIn) ->
    Queue = rbdict:fetch(Label, QueueMap),
    QueueMap1 = rbdict:store(Label, queue:in(MsgIn, Queue)),
    Gather#gather{queue_map=QueueMap1}.
    
gather_is_ready(#gather{queue_map=QueueMap}) ->
    NotReadyEntries = rbdict:filter(fun gather_is_label_not_ready/2, QueueMap),
    case rbdict:size(NotReadyEntries) of
	0 -> true;
	_ -> false
    end.

gather_is_label_not_ready(_, Queue) ->
    queue:is_empty(Queue).

gather_gen_args(Gather=#gather{queue_map=QueueMap}) ->
    MapFn = fun(_, Queue) -> 
		    {value, Msg4Label, Queue1} = queue:out(Queue),
		    {Msg4Label, Queue1}   
	    end,
    {ArgMap, QueueMap1} = rbdict_map_and_unzip2(MapFn, QueueMap),
    {ok, rbdict:to_list(ArgMap), Gather#gather{queue_map=QueueMap1}}.

make_error(From, Label, MsgIn, Reason,Args) ->
    Params = [
	      {from, From},
	      {label, Label},
	      {msg_in, MsgIn}
	     ],
    Args1 = lists:append(Params, Args),
    {error, Reason, Args1}.
    
rbdict_map_and_unzip2(MapFn, RbDict) ->
    LeftFn = fun(_, {Msg4Label, _}) -> Msg4Label end,
    RightFn = fun(_, {_, Queue}) -> Queue end,
    RbDict1 = rbdict:map(MapFn, RbDict),
    LeftRbDict = rbdict:map(LeftFn, RbDict1),
    RightRbDict = rbdict:map(RightFn, RbDict1),
    {LeftRbDict, RightRbDict}.

make_piper_fn(From, Label, MsgIn) ->
    fun 
	(Route=#route{type=call}, ErrorAcc) ->
	    MsgOut = case Route#route.generator of
			 none -> MsgIn;
			 Generator -> Generator(MsgIn)
		     end,
	    case gen_server:call(Route#route.dest_server, MsgOut) of
		{ok, Returned} ->
		    gen_server:cast(?MODULE, {self(), Route#route.dest_label, Returned}),
		    ErrorAcc;
		{error, Reason, Args} -> 
		    [make_error(From, Label, MsgIn, Reason, Args) | ErrorAcc]
	    end;
	(Route=#route{type=cast}, ErrorAcc) ->
	    MsgOut = case Route#route.generator of
			 none -> MsgIn;
			 Generator -> Generator(MsgIn)
		     end,
	    gen_server:cast(Route#route.dest_server, MsgOut),
	    ErrorAcc;
	(Route=#route{type=direct}, ErrorAcc) ->
	    MsgOut = case Route#route.generator of
			 none -> MsgIn;
			 Generator -> Generator(MsgIn)
		     end,
	    Route#route.dest_server ! MsgOut,
	    ErrorAcc
    end.
	    

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
% Cmd, Args, State#state.map
