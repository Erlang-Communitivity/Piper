README.md - Piper

Piper - A basic Erlang workflow engine designed to pipeline messages through orchestrations of OTP behaviors such as gen_servers.

Features (current):
* Simple straight pipeline, msgs to a label get routed as is to a gen_server:cast
* Result of a gen_server:call which processed a routed msg is itself routed to a new label
* Capability to apply a message builder to create an outgoing msg from the one that comes in at a label
* Splitter, Labels can have multiple destinations, out msg is sent to each
* Capability to gather msgs that come in at a set of labels into one outgoing message

Features (planned):
* Conditionals, msg is sent through route only if a predicate function for that route returns true, if function specified
* Label options can be set
* Label option: Pumping label. Option of {pumping, every, Milliseconds} causes the last message recevied to be re-sent out after a delay of Milliseconds
* Gather options can be set
* Gather option: until a new message is received a message is not deleted off the queue for a label. A new msg for that label causes
  that msg to replace the old one at the head of the queue

Example for current features:

Goal: Produce an HTML page listing article metadata, in descending date order, from three blog entries.

We'll use the following record for each piece of metadata from our RSS feeds:
-record(entry, {
	       title,  %% title of the entry
	       link,
	       date,
	       description,
	       guid,
	       source
}). 
Source is defined by
-record(source, {title, link}).

We'll also assume with have a urlpiper running for each of the following three URLs, long enough to have already cached results and setup to cache xmerl parse results:
* http://www.npr.org/rss/rss.php?id=1019
* http://www.smartertechnology.com/rss-feeds-5.xml
* http://www.smartertechnology.com/rss-feeds-9.xml

First let's talk through our processing pipeline.  We'll start with a single message coming into the 'start' label. That label will split to three routes. All three routes will send a message of *content* using gen_server:call to the appropriate urlpiper instance.  The output from that call will be sent to the labels feed_npr, feed_smartertech_5, feed_smartertech_9 respectively. Each of those labels routes to a gen_server:call that takes the feed and produces a result of {Source records, List fo Entry records}. These are routed to entries_npr, entries_smartertech_5, entries_smartertech_9 respectively. A gather is set up to collect inputs for these labels, with a generator that combines the results in a proplist. The result is sent to a gen_server locally named entry_combiner designed to handle a call of form {entries, [{Source, Entries}+] }. This outputs {entries, [Entry+]} to label entries.  That label routes to a gen_server that produces a JSON serialization of the entries, suitable for use with Backbone Collection (see http://stackoverflow.com/questions/5501562/backbone-fetch-collection-from-server).  This  is then routed to the cache label. The generator for this label creates two gen_fsm events. In order of creation they are:
{line, "set feed_model 0 0 "++bytecount(Json)}
{line, JsonWithLineFeedsStripped}
These are sent to the oncecached_server (see http://www.process-one.net/en/blogs/article/processone_releases_onecached_a_memcached_in_erlang ), which stores the model in the memcached implementation  with key feed_model.

Now are web app, which consists of two pages. The first page, at URL /cache/feed_model, simply returns the contents of the feed_model memcache entry as JSON.  If no such key exists an empty model is returned.  The second page loads this model via Backbone (see http://stackoverflow.com/questions/5501562/backbone-fetch-collection-from-server) and displays it using the sortable 

Hmm, maybe not Backbone. Dojo is much improved, see http://www.sitepen.com/blog/2008/11/21/effective-use-of-jsonreststore-referencing-lazy-loading-and-more/.

Kind of like http://stackoverflow.com/questions/5651629/backbone-js-collections-and-views, but that has no table.
Also see http://dojotoolkit.org/documentation/tutorials/1.6/data_modeling/
http://www.sitepen.com/blog/2011/09/30/dojox-app-a-single-page-application-framework/
http://stackoverflow.com/questions/7373095/data-table-grid-widget-with-backbone-js <-- has a good solution for use with Backbone
https://github.com/flatiron/director#client-side
http://addyosmani.com/blog/building-spas-jquerys-best-friends/

Looking like best bet is Backbone + Flatiron's Director + TableSorter (http://tablesorter.com/docs/)
https://github.com/ostinelli/misultin/wiki/ExamplesPage
