import kvstore;
import std;
import ykey;

# by leveraging kvstore we won't need to use headers to carry option values,
# cleaning the requests and the logs
sub vcl_init {
	# scope = REQUEST defines a global store that can be overridden at the
	# request level
	new invalidate_opts = kvstore.init(scope = REQUEST);
	// PURGE, BAN, PURGEALL,  and PURGETAG are allowed by default
	invalidate_opts.set("purge-allow", "true");
	invalidate_opts.set("ban-allow", "true");
	invalidate_opts.set("purgeall-allow", "true");
	invalidate_opts.set("purgetag-allow", "true");
	// should BAN take the host header into acount
	invalidate_opts.set("ban-ignore-host", "false");
	// the default is to not trust a request, until told otherwise
	invalidate_opts.set("user-authorized", "false");
}

// each implementation will check if the user is authorized and if the method
// is enabled
sub invalidate_method_check {
	if (invalidate_opts.get("user-authorized") != "true") {
		invalidate_opts.set("message", "Unauthorized request");
		return (synth(405));
	}

	if (invalidate_opts.get(std.tolower(req.method) + "-allow") != "true") {
		invalidate_opts.set("message", req.method + " is disabled on this host");
		return (synth(405));
	}
}

sub invalidate {
	// for each method, check if the configuration allows it, and invalidate
	// according to it, setting req.http.invalidate-message
	if (req.method == "PURGE") {
		call invalidate_method_check;
		invalidate_opts.set("message", "Successful purge request");
		return (purge);
	} else if (req.method == "BAN") {
		call invalidate_method_check;
		if (invalidate_opts.get("ban-ignore-host") == "true") {
			ban("obj.http.invalidate-url ~ ^" + req.url);
		} else {
			ban("obj.http.invalidate-url ~ ^" + req.url + " && obj.http.invalidate-host == " + req.http.host);
		}
		invalidate_opts.set("message", "Successful ban request");
		return (synth(200));
	} else if (req.method == "PURGEALL") {
		call invalidate_method_check;
		ban("obj.status != 0");
		invalidate_opts.set("message", "Successful purgeall request");
		return (synth(200));
	} else if (req.method == "PURGETAG") {
		call invalidate_method_check;
		invalidate_opts.set("message", "Successful purgetag request: " + ykey.purge_header(req.http.purgetag-list) + " objects removed");
		return (synth(200));
	}
}

// add headers to beresp before it enters the cache, and make it a function
// to use fromboth v_b_r and v_b_e
sub invalidate_flag {
	set beresp.http.invalidate-url = bereq.url;
	set beresp.http.invalidate-host = bereq.http.host;
}

sub vcl_backend_response {
	call invalidate_flag;
}

sub vcl_backend_error {
	call invalidate_flag;
}

// remove headers before sending the reponse sso the users don't see them
sub vcl_deliver {
	unset resp.http.invalidate-url;
	unset resp.http.invalidate-host;
}

// check if req.http.invalidate-message and use it if so, short-circuiting the
// usual function
sub vcl_synth {
	if (invalidate_opts.get("message")) {
		synthetic (invalidate_opts.get("message"));
		return (deliver);
	}
}
