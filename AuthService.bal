import ballerina/http;
import ballerina/log;
import ballerina/jwt;
import ballerina/url;
import ballerina/uuid;
import ballerina/time;
import mongodb_atlas_app.mongodb;

@http:ServiceConfig {
    cors: {
        allowOrigins: ["http://localhost:3000", "http://localhost:5173"],
        allowCredentials: true,
        allowHeaders: ["content-type", "authorization"],
        allowMethods: ["POST", "GET", "OPTIONS", "PUT", "DELETE"],
        maxAge: 84900
    }
}

service /api/auth on ln {

   // REPLACE YOUR EXISTING signup ENDPOINT WITH THIS:

resource function post signup(http:Caller caller, http:Request req) returns error? {
    // Parse the JSON payload from the request body
    json signupPayload = check req.getJsonPayload();
    
    // Log redacted payload for security (we'll omit the password entirely)
    log:printInfo("New signup request received for user: " + (signupPayload.username is string ? (check signupPayload.username).toString() : "unknown"));
    
    // Extract all possible fields from the frontend payload
    string username = check signupPayload.username.ensureType();
    string password = check signupPayload.password.ensureType();
    
    // Handle the name field - we'll look for it in the payload, but it might be missing
    string name = "";
    if (signupPayload.name is string) {
        name = check signupPayload.name.ensureType();
    }
    
    // Use defaults for other potentially missing fields
    boolean isAdmin = false;
    if (signupPayload.isadmin is boolean) {
        isAdmin = check signupPayload.isadmin.ensureType();
    }
    
    string role = "";
    if (signupPayload.role is string) {
        role = check signupPayload.role.ensureType();
    }
    
    string phoneNumber = "";
    if (signupPayload.phone_number is string) {
        phoneNumber = check signupPayload.phone_number.ensureType();
    }
    
    string profilePic = "";
    if (signupPayload.profile_pic is string) {
        profilePic = check signupPayload.profile_pic.ensureType();
    }
    
    // Validate required fields
    if (username == "" || password == "") {
        log:printError("Missing required fields for signup");
        http:Response badRequestResponse = new;
        badRequestResponse.statusCode = 400; // Bad Request status code
        badRequestResponse.setJsonPayload({"error": "Username and password are required fields"});
        check caller->respond(badRequestResponse);
        return;
    }
    
    // If name is not provided, use username as name
    if (name == "") {
        name = username;
    }

    // Check if the user already exists in the collection using username field
    map<json> filter = {"username": username};
    stream<User, error?> userStream = check mongodb:userCollection->find(filter);
    record {|User value;|}? existingUser = check userStream.next();
    
    if (existingUser is record {|User value;|}) {
        log:printError("User already exists");
        http:Response conflictResponse = new;
        conflictResponse.statusCode = 409; // Conflict status code
        conflictResponse.setJsonPayload({"error": "User already exists"});
        check caller->respond(conflictResponse);
        return;
    }
    
    // Hash the password before storing
    string hashedPassword = hashPassword(password);
    
    // Create a new User record with the extracted fields
    User newUser = {
        username: username,
        name: name,
        password: hashedPassword
        // All other fields will use their default values
    };
    
    // If there are additional fields in User type that we want to set
    if (role != "") {
        newUser.role = role;
    }
    
    if (phoneNumber != "") {
        newUser["phone_number"] = phoneNumber;
    }
    
    if (profilePic != "") {
        newUser["profile_pic"] = profilePic;
    }
    
    // Set isAdmin if it's part of the User type
    if (isAdmin) {
        newUser["isadmin"] = isAdmin;
    }
    
    // Insert the new user into the MongoDB collection
    check mongodb:userCollection->insertOne(newUser);

    // ** NEW: Send welcome email for new registration **
    sendWelcomeEmailAsync(username, name);

    // Send a success response
    http:Response response = new;
    response.statusCode = 201; // Created status code
    response.setJsonPayload({"message": "User signed up successfully"});
    check caller->respond(response);
}
    // Add to service.bal inside the service definition
    resource function get status(http:Request req) returns LoginResponse|ErrorResponse|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "User not authenticated",
                statusCode: 401
            };
        }

        // Get user details from database
        map<json> filter = {
            "username": username
        };

        record {}|() userRecord = check mongodb:userCollection->findOne(filter);
        if userRecord is () {
            return {
                message: "User not found",
                statusCode: 404
            };
        }

        // Convert to User type
        json userJson = userRecord.toJson();
        User user = check userJson.cloneWithType(User);

        // Create login response without sensitive data
        LoginResponse response = {
            username: user.username,
            name: user.name,
            isadmin: user.isadmin,
            role: user.role,
            success: true,
            calendar_connected: user.calendar_connected
        };

        return response;
    }

  // REPLACE YOUR EXISTING login ENDPOINT WITH THIS:

resource function post login(http:Caller caller, http:Request req) returns error? {
    // Parse the JSON payload from the request body
    json loginPayload = check req.getJsonPayload();
    
    // Log the login attempt without password
    log:printInfo("Login attempt for user: " + (loginPayload.username is string ? (check loginPayload.username).toString() : "unknown"));
    
    // Convert JSON to LoginRequest type
    LoginRequest loginDetails = check loginPayload.cloneWithType(LoginRequest);
    
    // First, find the user by username
    map<json> usernameFilter = {"username": loginDetails.username};
    stream<User, error?> userStream = check mongodb:userCollection->find(usernameFilter);
    record {|User value;|}? userRecord = check userStream.next();
    
    if (userRecord is ()) {
        log:printError("Invalid username or password");
        http:Response unauthorizedResponse = new;
        unauthorizedResponse.statusCode = 401; // Unauthorized status code
        unauthorizedResponse.setJsonPayload({"error": "Invalid username or password"});
        check caller->respond(unauthorizedResponse);
        return;
    }
    
    User user = userRecord.value;
    
    // Hash the provided password and compare with stored hash
    string hashedInputPassword = hashPassword(loginDetails.password);
    
    if (hashedInputPassword != user.password) {
        log:printError("Invalid username or password");
        http:Response unauthorizedResponse = new;
        unauthorizedResponse.statusCode = 401; // Unauthorized status code
        unauthorizedResponse.setJsonPayload({"error": "Invalid username or password"});
        check caller->respond(unauthorizedResponse);
        return;
    }
    
    // Generate a new refresh token
    string refreshToken = uuid:createType1AsString();
    
    // Update the user record with the new refresh token
    map<json> filter = {"username": user.username};
    mongodb:Update updateOperation = {
        "set": {"email_refresh_token": refreshToken}
    };
    _ = check mongodb:userCollection->updateOne(filter, updateOperation);
    
    // Generate JWT token 
    string token = check generateJwtToken(user);
    
    // Get current time and device info
    time:Utc utcNow = time:utcNow();
    string currentTime = time:utcToString(utcNow);
    string|http:HeaderNotFoundError userAgentResult = req.getHeader("User-Agent");
    string userAgent = userAgentResult is string ? userAgentResult : "Chrome Extension";
    
    // Send login welcome email asynchronously (non-blocking)
    // sendLoginWelcomeEmailAsync(user.username, user.name, currentTime, userAgent);
    // sendLoginWelcomeEmailAsync(user.username, user.name, currentTime, userAgent);
    
    // Create login response - no token in the response body
    LoginResponse loginResponse = {
        username: user.username,
        name: user.name,
        isadmin: user.isadmin,
        role: user.role,
        success: true,
        calendar_connected: user.calendar_connected
    };

    json loginResponseJson = loginResponse.toJson();
    
    // Send the response with the JWT token in HttpOnly secure cookie
    http:Response response = new;
    response.setJsonPayload(loginResponseJson);
    
        // Set the JWT token as an HttpOnly secure cookie
        http:Cookie jwtCookie = new("auth_token", token, 
            path = "/", 
            httpOnly = true, 
            secure = true,
            maxAge = 3600 // 1 hour, matching the JWT expiration
        );

        // Set the refresh token in a separate cookie with longer expiration
        http:Cookie refreshCookie = new("refresh_token", refreshToken, 
            path = "/api/auth/refresh", // Restrict to refresh endpoint only
            httpOnly = true, 
            secure = true,
            maxAge = 2592000 // 30 days
        );

        response.addCookie(jwtCookie);
        response.addCookie(refreshCookie);
        check caller->respond(response);
    }

    resource function post refresh(http:Caller caller, http:Request req) returns error? {
        // Get the refresh token from the cookie
        string? refreshToken = ();
        http:Cookie[] cookies = req.getCookies();
        
        foreach http:Cookie cookie in cookies {
            if cookie.name == "refresh_token" {
                refreshToken = cookie.value;
                break;
            }
        }
        
        // If no refresh token in cookie, try to get it from the request body
        if refreshToken is () {
            json|http:ClientError jsonPayload = req.getJsonPayload();
            
            if jsonPayload is http:ClientError {
                http:Response badRequestResponse = new;
                badRequestResponse.statusCode = 400;
                badRequestResponse.setJsonPayload({"error": "Invalid request format"});
                check caller->respond(badRequestResponse);
                return;
            }
            
            RefreshTokenRequest tokenRequest = check jsonPayload.cloneWithType(RefreshTokenRequest);
            refreshToken = tokenRequest.refresh_token;
        }
        
        // Validate the refresh token exists
        if refreshToken is () || refreshToken == "" {
            http:Response unauthorizedResponse = new;
            unauthorizedResponse.statusCode = 401;
            unauthorizedResponse.setJsonPayload({"error": "Refresh token is required"});
            check caller->respond(unauthorizedResponse);
            return;
        }
        
        // Find user by refresh token
        map<json> filter = {"email_refresh_token": refreshToken};
        stream<User, error?> userStream = check mongodb:userCollection->find(filter);
        record {|User value;|}? userRecord = check userStream.next();
        
        if userRecord is () {
            // If no user found with this refresh token, try looking for Google refresh token
            map<json> googleFilter = {"refresh_token": refreshToken};
            stream<User, error?> googleUserStream = check mongodb:userCollection->find(googleFilter);
            userRecord = check googleUserStream.next();
            
            if userRecord is () {
                log:printError("Invalid refresh token");
                http:Response unauthorizedResponse = new;
                unauthorizedResponse.statusCode = 401;
                unauthorizedResponse.setJsonPayload({"error": "Invalid refresh token"});
                check caller->respond(unauthorizedResponse);
                return;
            }
        }
        
        // Safely unwrap the record since we now know it's not null
        User user;
        if userRecord is record {|User value;|} {
            user = userRecord.value;
        } else {
            // This should never happen since we checked above, but added for completeness
            log:printError("Unexpected error: userRecord is not of the expected type");
            http:Response errorResponse = new;
            errorResponse.statusCode = 500;
            errorResponse.setJsonPayload({"error": "Internal server error"});
            check caller->respond(errorResponse);
            return;
        }
        
        // Generate a new refresh token
        string newRefreshToken = uuid:createType1AsString();
        
        // Update the user record with the new refresh token
        map<json> updateFilter = {"username": user.username};
        mongodb:Update updateOperation = {
            "set": {"email_refresh_token": newRefreshToken}
        };
        _ = check mongodb:userCollection->updateOne(updateFilter, updateOperation);
        
        // Generate a new JWT token
        string newToken = check generateJwtToken(user);
        
        // Create the response
        http:Response response = new;
        
        // Set the new JWT token as an HttpOnly secure cookie
        http:Cookie jwtCookie = new("auth_token", newToken, 
            path = "/", 
            httpOnly = true, 
            secure = true,
            maxAge = 3600 // 1 hour, matching the JWT expiration
        );
        
        // Set the new refresh token in a separate cookie with longer expiration
        http:Cookie refreshCookie = new("refresh_token", newRefreshToken, 
            path = "/api/auth/refresh", // Restrict to refresh endpoint only
            httpOnly = true, 
            secure = true,
            maxAge = 2592000 // 30 days
        );
        
        response.addCookie(jwtCookie);
        response.addCookie(refreshCookie);
        
        // Include minimal user info in the response
        json responseBody = {
            "username": user.username,
            "name": user.name,
            "message": "Token refreshed successfully"
        };
        
        response.setJsonPayload(responseBody);
        check caller->respond(response);
    }

    
    // Updated Google login endpoint
    resource function post googleLogin(http:Caller caller, http:Request req) returns error? {
        // Parse the JSON payload from the request body
        json googleLoginPayload = check req.getJsonPayload();
        
        // Log the received payload for debugging (excluding sensitive data)
        log:printInfo("Google login request for: " + (googleLoginPayload.email is string ? (check googleLoginPayload.email).toString() : "unknown"));
        
        // Convert JSON to GoogleLoginRequest type
        GoogleLoginRequest googleDetails = check googleLoginPayload.cloneWithType(GoogleLoginRequest);
        
        // Check if the user exists with the provided Google ID
        map<json> filter = {"googleid": googleDetails.googleid};
        stream<User, error?> userStream = check mongodb:userCollection->find(filter);
        record {|User value;|}? userRecord = check userStream.next();
        
        User user;
        
        if (userRecord is ()) {
            // User doesn't exist - create a new account
            // Generate a secure random password and hash it
            string randomPassword = uuid:createType1AsString();
            string hashedPassword = hashPassword(randomPassword);
            
            user = {
                username: googleDetails.email, // Using email as username
                name: googleDetails.name,      // Use the name from Google account
                password: hashedPassword,      // Store hashed random password
                googleid: googleDetails.googleid,
                profile_pic: googleDetails.picture,
                calendar_connected: false,
                refresh_token: ""
            };
            
            // Insert the new user into the MongoDB collection
            check mongodb:userCollection->insertOne(user);
            log:printInfo("New user created from Google login: " + googleDetails.email);
        } else {
            // User exists
            user = userRecord.value;
            log:printInfo("Existing user logged in via Google: " + user.username);
        }
        
        // Generate JWT token
        string token = check generateJwtToken(user);
        
        // Create login response - no token in the response
        LoginResponse loginResponse = {
            username: user.username,
            name: user.name,
            isadmin: user.isadmin,
            role: user.role,
            success: true,
            calendar_connected: user.calendar_connected
        };

        json loginResponseJson = loginResponse.toJson();
        
        // Send the response with the JWT token in HttpOnly secure cookie
        http:Response response = new;
        response.setJsonPayload(loginResponseJson);
        
        // Set the JWT token as an HttpOnly secure cookie
        http:Cookie jwtCookie = new("auth_token", token, 
            path = "/", 
            httpOnly = true, 
            secure = true,
            maxAge = 3600 // 1 hour, matching the JWT expiration
        );

        response.addCookie(jwtCookie);
        check caller->respond(response);
    }
    
    // Updated Google OAuth flow to include calendar permissions
    resource function get google() returns http:Response|error {
        // Include calendar-related scopes in the permission request
        string encodedRedirectUri = check url:encode(googleRedirectUri, "UTF-8");
        string authUrl = string `https://accounts.google.com/o/oauth2/v2/auth?client_id=${googleClientId}&response_type=code&scope=email%20profile%20https://www.googleapis.com/calendar&redirect_uri=${encodedRedirectUri}&access_type=offline&prompt=consent`;
        
        // Create a redirect response
        http:Response response = new;
        response.statusCode = 302; // Found/Redirect status code
        response.setHeader("Location", authUrl);
        return response;
    }
    
    // Updated Google OAuth callback to handle calendar integration
    resource function get google/callback(http:Caller caller, http:Request req) returns error? {
        // Extract the authorization code from the query parameters
        string? code = req.getQueryParamValue("code");
        
        if (code is ()) {
            log:printError("No authorization code received from Google");
            http:Response errorResponse = new;
            errorResponse.statusCode = 400;
            errorResponse.setJsonPayload({"error": "No authorization code received"});
            check caller->respond(errorResponse);
            return;
        }
        
        // Exchange the code for tokens - Fixed URL encoding
        http:Client googleTokenClient = check new ("https://oauth2.googleapis.com");
        http:Request tokenRequest = new;
        string encodedRedirectUri = check url:encode(googleRedirectUri, "UTF-8");
        tokenRequest.setTextPayload(string `code=${code}&client_id=${googleClientId}&client_secret=${googleClientSecret}&redirect_uri=${encodedRedirectUri}&grant_type=authorization_code`, "application/x-www-form-urlencoded");
        
        http:Response tokenResponse = check googleTokenClient->post("/token", tokenRequest);
        json tokenJson = check tokenResponse.getJsonPayload();
        
        string accessToken = check tokenJson.access_token;
        
        // Store refresh token if provided (will be used for calendar API calls)
        string refreshToken = "";
        if (tokenJson.refresh_token is string) {
            refreshToken = check tokenJson.refresh_token;
            log:printInfo("Received refresh token for calendar access");
        }
        
        // Get user profile information
        http:Client googleUserClient = check new ("https://www.googleapis.com");
        
        map<string|string[]> headers = {"Authorization": "Bearer " + accessToken};
        http:Response userInfoResponse = check googleUserClient->get("/oauth2/v1/userinfo", headers);
        
        json userInfo = check userInfoResponse.getJsonPayload();
        
        string googleId = check userInfo.id;
        string email = check userInfo.email;
        string name = check userInfo.name;
        string? picture = check userInfo.picture;
        
        // Check if user already exists with this Google ID
        map<json> filter = {"googleid": googleId};
        stream<User, error?> userStream = check mongodb:userCollection->find(filter);
        record {|User value;|}? userRecord = check userStream.next();
        
        User user;
        boolean calendarConnected = false;
        
        if (userRecord is ()) {
            // Create a new user with a hashed random password
            string randomPassword = uuid:createType1AsString();
            string hashedPassword = hashPassword(randomPassword);
            
            // Attempt to verify calendar access if refresh token is available
            if (refreshToken != "") {
                calendarConnected = check verifyCalendarAccess(accessToken);
            }
            
            user = {
                username: email,
                name: name,
                password: hashedPassword,
                googleid: googleId,
                profile_pic: picture is string ? picture : "",
                calendar_connected: calendarConnected,
                refresh_token: refreshToken
            };
            
            check mongodb:userCollection->insertOne(user);
            log:printInfo("New user created with Google login: " + email + ", Calendar connected: " + calendarConnected.toString());
        } else {
            user = userRecord.value;
            
            // Update user with refresh token and check calendar access
            if (refreshToken != "") {
                calendarConnected = check verifyCalendarAccess(accessToken);
                
                // Update user record with new calendar connection status and refresh token
                map<json> userFilter = {"username": user.username};
                mongodb:Update updateDoc = {
                    "set": {
                        "calendar_connected": calendarConnected, 
                        "refresh_token": refreshToken
                    }
                };
                _ = check mongodb:userCollection->updateOne(userFilter, updateDoc);
                
                // Update local user object with new values
                user.calendar_connected = calendarConnected;
                user.refresh_token = refreshToken;
                
                log:printInfo("Updated user's calendar connection: " + user.username + ", Calendar connected: " + calendarConnected.toString());
            }
        }
        
        // Generate JWT token
        string token = check generateJwtToken(user);
        
        // Create HTML response with redirect
        string htmlResponse = string `
        <!DOCTYPE html>
        <html>
        <head>
            <title>Login Successful</title>
            <script>
                // Redirect to application dashboard without storing token
                // (token is managed by the HttpOnly cookie)
                window.location.href = '${frontendBaseUrl}/';
            </script>
        </head>
        <body>
            <h2>Login Successful!</h2>
            <p>Redirecting...</p>
        </body>
        </html>
        `;
        
        http:Response response = new;
        response.setTextPayload(htmlResponse);
        response.setHeader("Content-Type", "text/html");
        
        // Set the JWT token as an HttpOnly secure cookie
        http:Cookie jwtCookie = new("auth_token", token, 
            path = "/", 
            httpOnly = true, 
            secure = true,
            maxAge = 3600 // 1 hour, matching the JWT expiration
        );

        response.addCookie(jwtCookie);
        check caller->respond(response);
    }
    
    // New endpoint to connect Google Calendar separately
    resource function get connectCalendar(http:Caller caller, http:Request req) returns error? {
        // First, verify user is authenticated by checking JWT in cookie
        string authToken = "";
        http:Cookie[] cookies = req.getCookies();
        
        foreach http:Cookie cookie in cookies {
            if (cookie.name == "auth_token") {
                authToken = cookie.value;
                break;
            }
        }
        
        if (authToken == "") {
            http:Response unauthorizedResponse = new;
            unauthorizedResponse.statusCode = 401;
            unauthorizedResponse.setJsonPayload({"error": "Authentication required"});
            check caller->respond(unauthorizedResponse);
            return;
        }
        
        // Validate the token
        jwt:ValidatorConfig validatorConfig = {
            issuer: "automeet",
            audience: "automeet-app",
            signatureConfig: {
                secret: JWT_SECRET
            }
        };
        jwt:Payload|jwt:Error payload = jwt:validate(authToken, validatorConfig);
        
        if (payload is jwt:Error) {
            http:Response unauthorizedResponse = new;
            unauthorizedResponse.statusCode = 401;
            unauthorizedResponse.setJsonPayload({"error": "Invalid or expired token"});
            check caller->respond(unauthorizedResponse);
            return;
        }
        
        // Extract username from validated token
        string username = "";
        if (payload is jwt:Payload) {
            // Get the username from the 'sub' field
            username = payload.sub ?: "";
        }
                
        // Include calendar-specific scopes and use the calendar redirect URI
        string encodedRedirectUri = check url:encode(googleCalendarRedirectUri, "UTF-8");
        string authUrl = string `https://accounts.google.com/o/oauth2/v2/auth?client_id=${googleClientId}&response_type=code&scope=https://www.googleapis.com/calendar&redirect_uri=${encodedRedirectUri}&access_type=offline&prompt=consent&state=${username}`;
        
        // Create a redirect response to Google's OAuth page
        http:Response response = new;
        response.statusCode = 302; // Found/Redirect status code
        response.setHeader("Location", authUrl);
        check caller->respond(response);
    }
    
    // Callback endpoint specifically for calendar connection
    resource function get google/calendar/callback(http:Caller caller, http:Request req) returns error? {
        // Extract authorization code and state (username) from query parameters
        string? code = req.getQueryParamValue("code");
        string? username = req.getQueryParamValue("state");
        
        if (code is () || username is ()) {
            log:printError("Missing code or username for calendar connection");
            http:Response errorResponse = new;
            errorResponse.statusCode = 400;
            errorResponse.setJsonPayload({"error": "Missing required parameters"});
            check caller->respond(errorResponse);
            return;
        }
        
        // Exchange the code for tokens using the calendar-specific redirect URI
        http:Client googleTokenClient = check new ("https://oauth2.googleapis.com");
        http:Request tokenRequest = new;
        string encodedRedirectUri = check url:encode(googleCalendarRedirectUri, "UTF-8");
        tokenRequest.setTextPayload(string `code=${code}&client_id=${googleClientId}&client_secret=${googleClientSecret}&redirect_uri=${encodedRedirectUri}&grant_type=authorization_code`, "application/x-www-form-urlencoded");
        
        http:Response tokenResponse = check googleTokenClient->post("/token", tokenRequest);
        json tokenJson = check tokenResponse.getJsonPayload();
        
        string accessToken = check tokenJson.access_token;
        
        // Get refresh token for long-term access to calendar
        string refreshToken = "";
        if (tokenJson.refresh_token is string) {
            refreshToken = check tokenJson.refresh_token;
        } else {
            log:printError("No refresh token received for calendar connection");
            http:Response errorResponse = new;
            errorResponse.statusCode = 400;
            errorResponse.setJsonPayload({"error": "Failed to get necessary permissions for calendar"});
            check caller->respond(errorResponse);
            return;
        }
        
        // Verify calendar access
        boolean calendarConnected = check verifyCalendarAccess(accessToken);
        
        if (!calendarConnected) {
            log:printError("Failed to verify calendar access");
            http:Response errorResponse = new;
            errorResponse.statusCode = 400;
            errorResponse.setJsonPayload({"error": "Failed to connect to Google Calendar"});
            check caller->respond(errorResponse);
            return;
        }
        
        // Update user record with calendar connection info
        map<json> userFilter = {"username": username};
        mongodb:Update updateDoc = {
            "set": {
                "calendar_connected": true, 
                "refresh_token": refreshToken
            }
        };
        
        var updateResult = mongodb:userCollection->updateOne(userFilter, updateDoc);
        
        if (updateResult is error) {
            log:printError("Failed to update user with calendar connection", updateResult);
            http:Response errorResponse = new;
            errorResponse.statusCode = 500;
            errorResponse.setJsonPayload({"error": "Failed to save calendar connection"});
            check caller->respond(errorResponse);
            return;
        }
        
        log:printInfo("Successfully connected calendar for user: " + username.toString());
        
        // Create HTML response with redirect to frontend
        string htmlResponse = string `
        <!DOCTYPE html>
        <html>
        <head>
            <title>Calendar Connected</title>
            <script>
                // Redirect to application dashboard
                window.location.href = '${frontendBaseUrl}/settings/calendarSync';
            </script>
        </head>
        <body>
            <h2>Google Calendar Connected Successfully!</h2>
            <p>Redirecting to dashboard...</p>
        </body>
        </html>
        `;
        
        http:Response response = new;
        response.setTextPayload(htmlResponse);
        response.setHeader("Content-Type", "text/html");
        check caller->respond(response);
    }
    
    // Add endpoint to check calendar connection status
    resource function get calendarStatus(http:Caller caller, http:Request req) returns error? {
        // First, verify user is authenticated by checking JWT in cookie
        string authToken = "";
        http:Cookie[] cookies = req.getCookies();
        
        foreach http:Cookie cookie in cookies {
            if (cookie.name == "auth_token") {
                authToken = cookie.value;
                break;
            }
        }
        
        if (authToken == "") {
            http:Response unauthorizedResponse = new;
            unauthorizedResponse.statusCode = 401;
            unauthorizedResponse.setJsonPayload({"error": "Authentication required"});
            check caller->respond(unauthorizedResponse);
            return;
        }
        
        // Validate the token
        jwt:ValidatorConfig validatorConfig = {
            issuer: "automeet",
            audience: "automeet-app",
            signatureConfig: {
                secret: JWT_SECRET
            }
        };
        jwt:Payload|jwt:Error payload = jwt:validate(authToken, validatorConfig);
        
        if (payload is jwt:Error) {
            http:Response unauthorizedResponse = new;
            unauthorizedResponse.statusCode = 401;
            unauthorizedResponse.setJsonPayload({"error": "Invalid or expired token"});
            check caller->respond(unauthorizedResponse);
            return;
        }
        
        // Extract username from validated token
        string username = "";
        if (payload is jwt:Payload) {
            // Get the username from the 'sub' field
            username = payload.sub ?: "";
        }
        
        // Get user from database to check calendar connection status
        map<json> userFilter = {"username": username};
        stream<User, error?> userStream = check mongodb:userCollection->find(userFilter);
        record {|User value;|}? userRecord = check userStream.next();
        
        if (userRecord is ()) {
            http:Response notFoundResponse = new;
            notFoundResponse.statusCode = 404;
            notFoundResponse.setJsonPayload({"error": "User not found"});
            check caller->respond(notFoundResponse);
            return;
        }
        
        User user = userRecord.value;
        
        // Create response with calendar connection status
        CalendarConnectionResponse statusResponse = {
            connected: user.calendar_connected,
            message: user.calendar_connected ? "Google Calendar is connected" : "Google Calendar is not connected"
        };
        
        http:Response response = new;
        response.setJsonPayload(statusResponse.toJson());
        check caller->respond(response);
    }
    
    // Add a logout endpoint to clear the cookie
    resource function get logout(http:Caller caller) returns error? {
        http:Response response = new;
        
        // Log the logout attempt
        log:printInfo("User logout requested");
        
        // Create an expired cookie to clear the auth token
        http:Cookie expiredCookie = new("auth_token", "",
            path = "/", 
            httpOnly = true, 
            secure = true,
            maxAge = 0 // Immediately expire the cookie
        );

        // Add CORS headers for cross-origin requests
        response.setHeader("Access-Control-Allow-Origin", "http://localhost:3000");
        response.setHeader("Access-Control-Allow-Credentials", "true");
        
        response.addCookie(expiredCookie);
        response.setJsonPayload({"message": "Logged out successfully"});
        check caller->respond(response);
        
        log:printInfo("User logged out successfully");
    }

    // Add this new endpoint to retrieve Gmail addresses with connected calendars
    resource function get connectedCalendarAccounts(http:Caller caller, http:Request req) returns error? {
        // First, verify the requesting user is authenticated and admin
        string authToken = "";
        http:Cookie[] cookies = req.getCookies();
        
        foreach http:Cookie cookie in cookies {
            if (cookie.name == "auth_token") {
                authToken = cookie.value;
                break;
            }
        }
        
        if (authToken == "") {
            http:Response unauthorizedResponse = new;
            unauthorizedResponse.statusCode = 401;
            unauthorizedResponse.setJsonPayload({"error": "Authentication required"});
            check caller->respond(unauthorizedResponse);
            return;
        }
        
        // Validate the token
        jwt:ValidatorConfig validatorConfig = {
            issuer: "automeet",
            audience: "automeet-app",
            signatureConfig: {
                secret: JWT_SECRET
            }
        };
        jwt:Payload|jwt:Error payload = jwt:validate(authToken, validatorConfig);
        
        if (payload is jwt:Error) {
            http:Response unauthorizedResponse = new;
            unauthorizedResponse.statusCode = 401;
            unauthorizedResponse.setJsonPayload({"error": "Invalid or expired token"});
            check caller->respond(unauthorizedResponse);
            return;
        }
        
        // Extract username from validated token
        string username = "";
        if (payload is jwt:Payload) {
            // Get the username from the 'sub' field
            username = payload.sub ?: "";
        }
        
        // Retrieve the user from the database to check admin status
        map<json> userFilter = {"username": username};
        stream<User, error?> adminCheckStream = check mongodb:userCollection->find(userFilter);
        record {|User value;|}? userRecord = check adminCheckStream.next();
        
        if (userRecord is ()) {
            http:Response notFoundResponse = new;
            notFoundResponse.statusCode = 404;
            notFoundResponse.setJsonPayload({"error": "User not found"});
            check caller->respond(notFoundResponse);
            return;
        }
        
        // Check if the user is an admin
        User currentUser = userRecord.value;
        if (!currentUser.isadmin) {
            http:Response forbiddenResponse = new;
            forbiddenResponse.statusCode = 403;
            forbiddenResponse.setJsonPayload({"error": "Only administrators can access this data"});
            check caller->respond(forbiddenResponse);
            return;
        }
        
        // Query MongoDB for users with connected calendars
        map<json> filter = {"calendar_connected": true};
        stream<User, error?> userStream = check mongodb:userCollection->find(filter);
        
        // Create an array to hold the emails
        json[] connectedEmails = [];
        
        // Process the stream of users
        error? e = userStream.forEach(function(User user) {
            // Add just the email (username) to the result array
            connectedEmails.push(user.username);
        });
        
        if (e is error) {
            http:Response errorResponse = new;
            errorResponse.statusCode = 500;
            errorResponse.setJsonPayload({"error": "Error retrieving connected accounts"});
            check caller->respond(errorResponse);
            return;
        }
        
        // Return the list of emails
        http:Response response = new;
        response.setJsonPayload({"connected_accounts": connectedEmails});
        check caller->respond(response);
    }

    // Disconnect calendar endpoint
    resource function post disconnectCalendar(http:Caller caller, http:Request req) returns error? {
        // First, verify user is authenticated by checking JWT in cookie
        string authToken = "";
        http:Cookie[] cookies = req.getCookies();
        
        foreach http:Cookie cookie in cookies {
            if (cookie.name == "auth_token") {
                authToken = cookie.value;
                break;
            }
        }
        
        if (authToken == "") {
            http:Response unauthorizedResponse = new;
            unauthorizedResponse.statusCode = 401;
            unauthorizedResponse.setJsonPayload({"error": "Authentication required"});
            check caller->respond(unauthorizedResponse);
            return;
        }
        
        // Validate the token
        jwt:ValidatorConfig validatorConfig = {
            issuer: "automeet",
            audience: "automeet-app",
            signatureConfig: {
                secret: JWT_SECRET
            }
        };
        jwt:Payload|jwt:Error payload = jwt:validate(authToken, validatorConfig);
        
        if (payload is jwt:Error) {
            http:Response unauthorizedResponse = new;
            unauthorizedResponse.statusCode = 401;
            unauthorizedResponse.setJsonPayload({"error": "Invalid or expired token"});
            check caller->respond(unauthorizedResponse);
            return;
        }
        
        // Extract username from validated token
        string username = "";
        if (payload is jwt:Payload) {
            // Get the username from the 'sub' field
            username = payload.sub ?: "";
        }
        
        // Update user record to disconnect calendar
        map<json> userFilter = {"username": username};
        mongodb:Update updateDoc = {
            "set": {
                "calendar_connected": false, 
                "refresh_token": ""
            }
        };
        
        var updateResult = mongodb:userCollection->updateOne(userFilter, updateDoc);
        
        if (updateResult is error) {
            log:printError("Failed to disconnect calendar for user", updateResult);
            http:Response errorResponse = new;
            errorResponse.statusCode = 500;
            errorResponse.setJsonPayload({"error": "Failed to disconnect calendar"});
            check caller->respond(errorResponse);
            return;
        }
        
        log:printInfo("Successfully disconnected calendar for user: " + username);
        
        // Create response
        http:Response response = new;
        response.setJsonPayload({"message": "Calendar disconnected successfully"});
        
        check caller->respond(response);
    }
    
}