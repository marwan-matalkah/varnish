vcl 4.0;
import directors;
import std;

acl purge {
        "localhost";
}

backend server1 {
    .host = "IP Address for backend Server 1";
    .port = "80";
	.probe = {
		.request =
		  "HEAD / HTTP/1.1"
		  "Host: example.com"
		  "Connection: close"
		  "User-Agent: Varnish Health Probe";

		.interval  = 30s; 
		.timeout   = 10s; 
		.window    = 5;  
		.threshold = 3;
	  }
}
backend server2 {
    .host = "IP Address for backend Server 2";
	.port = "80";
	.probe = {
		.request =
		  "HEAD / HTTP/1.1"
		  "Host: example.com"
		  "Connection: close"
		  "User-Agent: Varnish Health Probe";

		.interval  = 30s; 
		.timeout   = 10s; 
		.window    = 5;  
		.threshold = 3;
	  }
}

sub vcl_init {
    new default_director = directors.round_robin();
    default_director.add_backend(server1);
    default_director.add_backend(server2);
}

# Incoming requests: Decide whether to try cache or not
sub vcl_recv {

	set req.backend_hint = default_director.backend();

	if (req.method == "PURGE") {
        if (!client.ip ~ purge) {
            return(synth(405,"Not allowed."));
                }
            return (purge);
        }

  # Pipe all websocket requests.
  if (req.http.Upgrade ~ "(?i)websocket") {
    return(pipe);
  }

  # Varnish doesn't support Range requests: needs to be piped
  if (req.http.Range) {
    return(pipe);
  }
  
    # filtering out all URLs containing Drupal administrative sections
    if (req.url ~ "^/status\.php$" ||
        req.url ~ "^/update\.php$" ||
        req.url ~ "^/admin$" ||
        req.url ~ "^/admin/.*$" ||
        req.url ~ "^/user$" ||
        req.url ~ "^/user/.*$" ||
        req.url ~ "^/flag/.*$" ||
        req.url ~ "^.*/ajax/.*$" ||
        req.url ~ "^.*/ahah/.*$") {
           return (pass);
    }
	
  # Don't check cache for POSTs and various other HTTP request types
  if (req.method != "GET" && req.method != "HEAD") {
    return(pass);
  }

  # Always cache the following file types for all users if not coming from the private file system.
  if (req.url ~ "(?i)/(modules|themes|files|libraries)/.*\.(png|gif|jpeg|jpg|ico|swf|css|js|flv|f4v|mov|mp3|mp4|pdf|doc|ttf|eot|ppt|ogv|woff)(\?[a-z0-9]+)?$" && req.url !~ "/system/files") {
    unset req.http.Cookie;
    # Set header so we know to remove Set-Cookie later on.
    set req.http.X-static-asset = "True";
  }

  # Don't check cache for cron.php
  if (req.url ~ "^/cron.php") {
    return(pass);
  }

  # This is part of Varnish's default behavior to pass through any request that
  # comes from an http auth'd user.
  if (req.http.Authorization) {
    return(pass);
  }

    if (req.url ~ "^/admin/content/backup_migrate/export") {
    return (pipe);
  }
  
  if (req.http.Accept-Encoding) {
    if (req.http.Accept-Encoding ~ "gzip") {
      set req.http.Accept-Encoding = "gzip";
    }
    else if (req.http.Accept-Encoding ~ "deflate") {
      set req.http.Accept-Encoding = "deflate";
    }
    else {
      unset req.http.Accept-Encoding;
    }
  }
  
  # Don't check cache if the Drupal session cookie is set.
  if (req.http.Cookie) {
    set req.http.Cookie = ";" + req.http.Cookie;
    set req.http.Cookie = regsuball(req.http.Cookie, "; +", ";");
    set req.http.Cookie = regsuball(req.http.Cookie, ";(S?SESS[a-z0-9]+|NO_CACHE)=", "; \1=");
    set req.http.Cookie = regsuball(req.http.Cookie, ";[^ ][^;]*", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "^[; ]+|[; ]+$", "");

    if (req.http.Cookie == "") {
      unset req.http.Cookie;
    }
    else {
      return (pass);
    }
  }

  # Default cache check
  return(hash);
}

# piped requests should not support keepalive because
# Varnish won't have chance to process or log the subrequests
sub vcl_pipe {
  if (req.http.upgrade) {
    set bereq.http.upgrade = req.http.upgrade;
  }
  else {
    set req.http.connection = "close";
  }
}

# Backend response: Determine whether to cache each backend response
sub vcl_backend_response {
  # Pipe all requests for files whose Content-Length is >=10,000,000. See
  # comment in vcl_pipe.
  if ( beresp.http.Content-Length ~ "[0-9]{8,}" ) {
    set beresp.do_stream = true;
  }

  # Avoid attempting to gzip an empty response body
  # https://www.varnish-cache.org/trac/ticket/1320
  if (beresp.http.Content-Encoding ~ "gzip" && beresp.http.Content-Length == "0") {
    unset beresp.http.Content-Encoding;
  }

  # Remove the Set-Cookie header from static assets
  # This is just for cleanliness and is also done in vcl_deliver
  if (bereq.http.X-static-asset) {
    unset beresp.http.Set-Cookie;
  }

  # Make sure we are caching 301s for at least 15 mins.
  if (beresp.status == 301) {
    if (beresp.ttl < 15m) {
      set beresp.ttl = 15m;
    }
  }

  # Don't cache responses with status codes greater than 302 or
  # HEAD and POST requests.
  if (beresp.status >= 302 || !(beresp.ttl > 0s) || bereq.method != "GET") {
    call ah_pass;
  }

  # Respect explicit no-cache headers
  if (beresp.http.Pragma ~ "no-cache" ||
      beresp.http.Cache-Control ~ "no-cache" ||
      beresp.http.Cache-Control ~ "private") {
    call ah_pass;
  }

  # Don't cache cron.php
  if (bereq.url ~ "^/cron.php") {
    call ah_pass;
  }

  # NOTE: xmlrpc.php requests are not cached because they're POSTs

  # Don't cache if Drupal session cookie is set
  # Note: Pressflow doesn't send SESS cookies to anon users
  if (beresp.http.Set-Cookie ~ "SESS") {
    call ah_pass;
  }

  # Grace: Avoid thundering herd when an object expires by serving
  # expired stale object during the next N seconds while one request
  # is made to the backend for that object.
  set beresp.grace = 6h;

  # Cache anything else. Returning nothing here would fall-through
  # to Varnish's default cache store policies.
  return(deliver);
}

# Deliver the response to the client
sub vcl_deliver {

  # Add an X-Cache diagnostic header
  if (obj.hits > 0) {
    set resp.http.X-Cache = "HIT";
    set resp.http.X-Cache-Hits = obj.hits;
    # Don't echo cached Set-Cookie headers
    unset resp.http.Set-Cookie;
  } else {
    set resp.http.X-Cache = "MISS";
  }

  # Strip the age header for Akamai requests
  if (req.http.Via ~ "akamai") {
    set resp.http.X-Age = resp.http.Age;
    unset resp.http.Age;
  }

  # Remove the Set-Cookie header from static assets
  if (req.http.X-static-asset) {
    unset resp.http.Set-Cookie;
  }

  # Force Safari to always check the server as it doesn't respect Vary: cookie.
  # See https://bugs.webkit.org/show_bug.cgi?id=71509
  # Static assets may be cached however as we already forcefully remove the
  # cookies for them.
  if (req.http.user-agent ~ "Safari" && !req.http.user-agent ~ "Chrome" && !req.http.X-static-asset) {
    set resp.http.cache-control = "max-age: 0";
  }
  # ELB health checks respect HTTP keep-alives, but require the connection to
  # remain open for 60 seconds. Varnish's default keep-alive idle timeout is
  # 5 seconds, which also happens to be the minimum ELB health check interval.
  # The result is a race condition in which Varnish can close an ELB health
  # check connection just before a health check arrives, causing that check to
  # fail. Solve the problem by not allowing HTTP keep-alive for ELB checks.
  if (req.http.user-agent ~ "ELB-HealthChecker") {
    set resp.http.Connection = "close";
  }
   
  return(deliver);
}


# Backend down: Error page returned when all backend servers are down
sub vcl_synth {
  # mobile browsers redirect
  if (resp.status == 750) {
    set resp.http.Location = resp.reason + req.url;
    set resp.status = 302;
    set resp.reason = "Found";
    return(deliver);
  }

  set resp.http.Content-Type = "text/html; charset=utf-8";
  set resp.http.Retry-After = "5";
  synthetic( {"<!DOCTYPE html>
<html>
  <head>
    <title>"} + resp.status + " " + resp.reason + {"</title>
  </head>
  <body>
    <p>Error "} + resp.status + " " + resp.reason + {"</p>
    <p>"} + resp.reason + {"</p>
    <h3>Guru Meditation:</h3>
    <p>XID: "} + req.xid + {"</p>
    <hr>
    <p>Varnish cache server</p>
  </body>
</html>
"} );
  return (deliver);
}

# Backend down: Error page returned when all backend servers are down
sub vcl_backend_error {

  # Default Varnish error (Nginx didn't reply)
  set beresp.http.Content-Type = "text/html; charset=utf-8";

  synthetic( {"<!DOCTYPE html>
  <html>
    <head>
      <title>"} + beresp.status + " " + beresp.reason + {"</title>
    </head>
    <body>
    <p>Error "} + beresp.status + " " + beresp.reason + {"</p>
    <p>"} + beresp.reason + {"</p>
      <p>XID: "} + bereq.xid + {"</p>
    </body>
   </html>
   "} );
  return(deliver);
}

# Separate pass subroutine to shorten the lifetime of beresp.ttl
# This will reduce the amount of "Cache Hits for Pass" for objects
sub ah_pass {
  set beresp.uncacheable = true;
  set beresp.ttl = 10s;
  return(deliver);
}
