
-module(hayata_graph).

-behaviour(gen_server).

-export([
    start_link/0,
    start_link/1,
    get_state/1,
    replace_state/2,
    update_state/2
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-type graph_state() :: map().

-export_type([graph_state/0]).

%% Public API

-doc("Starts a graph process with an empty state.").
-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(#{}).

-doc("Starts a graph process with the supplied initial state.").
-spec start_link(graph_state()) -> gen_server:start_ret().
start_link(InitialState) when is_map(InitialState) ->
    gen_server:start_link(?MODULE, InitialState, []).

-doc("Returns the current graph state.").
-spec get_state(gen_server:server_ref()) ->
    graph_state().
get_state(Server) ->
    gen_server:call(Server, get_state).

-doc("Replaces the complete graph state.").
-spec replace_state(gen_server:server_ref(), graph_state()) ->
    ok.
replace_state(Server, NewState) when is_map(NewState) ->
    gen_server:call(Server, {replace_state, NewState}).

-doc("Merges the supplied keys into the current graph state.").
-spec update_state(gen_server:server_ref(), graph_state()) ->
    ok.
update_state(Server, Updates) when is_map(Updates) ->
    gen_server:call(Server, {update_state, Updates}).

%% gen_server callbacks

-doc(false).
-spec init(graph_state()) -> {ok, graph_state()}.
init(InitialState) ->
    {ok, InitialState}.

-doc(false).
-spec handle_call(term(), gen_server:from(), graph_state()) ->
    {reply, term(), graph_state()}.
handle_call(get_state, _From, State) ->
    {reply, State, State};
handle_call({replace_state, NewState}, _From, _State) ->
    {reply, ok, NewState};
handle_call({update_state, Updates}, _From, State) ->
    NewState = maps:merge(State, Updates),
    {reply, ok, NewState};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

-doc(false).
-spec handle_cast(term(), graph_state()) ->
    {noreply, graph_state()}.
handle_cast(_Request, State) ->
    {noreply, State}.

-doc(false).
-spec handle_info(term(), graph_state()) ->
    {noreply, graph_state()}.
handle_info(_Info, State) ->
    {noreply, State}.

-doc(false).
-spec terminate(term(), graph_state()) -> ok.
terminate(_Reason, _State) ->
    ok.

-doc(false).
-spec code_change(term(), graph_state(), term()) ->
    {ok, graph_state()}.
code_change(_OldVersion, State, _Extra) ->
    {ok, State}.
