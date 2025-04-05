import ballerina/http;
import ballerinax/mongodb;
import ballerina/log;
import ballerina/jwt;
import ballerina/time;
import ballerina/url;
import ballerina/uuid;

// Extended User record definition with name field
type User record {
    string username;
    string name;
    string password;
    boolean isadmin = false;
    string role = ""; 
    string phone_number = "";
    string profile_pic = "";
    string googleid = "";
};

// Login request payload
type LoginRequest record {
    string username;
    string password;
};

// Google login request payload
type GoogleLoginRequest record {
    string googleid;
    string email;
    string name;
    string picture = "";
};

// Login response with JWT token
type LoginResponse record {
    string token;
    string username;
    string name;        // Added name to response
    boolean isadmin;
    string role;
};

// Google OAuth config - add your client values in production
configurable string googleClientId = "751259024059-q80a9la618pq41b7nnua3gigv29e0f46.apps.googleusercontent.com";
configurable string googleClientSecret = "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";
configurable string googleRedirectUri = "http://localhost:8080/auth/google/callback";

mongodb:Client mongoDb = check new ({
    connection: "mongodb+srv://pabasara:20020706@mycluster.cb3avmr.mongodb.net/?retryWrites=true&w=majority&appName=mycluster"
});

// JWT signing key - in production, this should be in a secure configuration
final string & readonly JWT_SECRET = "6be1b0ba9fd7c089e3f8ce1bdfcd97613bbe986cf45c1eaec198108bad119bcbfe2088b317efb7d30bae8e60f19311ff13b8990bae0c80b4cb5333c26abcd27190d82b3cd999c9937647708857996bb8b836ee4ff65a31427d1d2c5c59ec67cb7ec94ae34007affc2722e39e7aaca590219ce19cec690ffb7846ed8787296fd679a5a2eadb7d638dc656917f837083a9c0b50deda759d453b8c9a7a4bb41ae077d169de468ec225f7ba21d04219878cd79c9329ea8c29ce8531796a9cc01dd200bb683f98585b0f98cffbf67cf8bafabb8a2803d43d67537298e4bf78c1a05a76342a44b2cf7cf3ae52b78469681b47686352122f8f1af2427985ec72783c06e";

@http:ServiceConfig {
    cors: {
        allowOrigins: ["http://localhost:3000"],
        allowCredentials: true,
        allowHeaders: ["content-type", "authorization"],
        allowMethods: ["POST", "GET", "OPTIONS"],
        maxAge: 84900
    }
}


service /auth on new http:Listener(8080) {
    mongodb:Database userDb;
    mongodb:Collection userCollection;
    
    function init() returns error? {
        self.userDb = check mongoDb->getDatabase("automeet");
        self.userCollection = check self.userDb->getCollection("user");
    }
    
    resource function post signup(http:Caller caller, http:Request req) returns error? {
        // Parse the JSON payload from the request body
        json signupPayload = check req.getJsonPayload();
        
        // Log the received payload for debugging
        log:printInfo(signupPayload.toString());
        
        // Convert JSON to User type with proper error handling
        User userDetails = check signupPayload.cloneWithType(User);
        
        // Validate required fields
        if (userDetails.name == "") {
            log:printError("Name is required");
            http:Response badRequestResponse = new;
            badRequestResponse.statusCode = 400;
            badRequestResponse.setJsonPayload({"error": "Name is required"});
            check caller->respond(badRequestResponse);
            return;
        }

        // Check if the user already exists in the collection using username field
        map<json> filter = {"username": userDetails.username};
        stream<User, error?> userStream = check self.userCollection->find(filter);
        record {|User value;|}? existingUser = check userStream.next();
        
        if (existingUser is record {|User value;|}) {
            log:printError("User already exists");
            http:Response conflictResponse = new;
            conflictResponse.statusCode = 409; // Conflict status code
            conflictResponse.setJsonPayload({"error": "User already exists"});
            check caller->respond(conflictResponse);
            return;
        }
        
        // Insert the new user into the MongoDB collection
        check self.userCollection->insertOne(userDetails);

        // Send a success response
        http:Response response = new;
        response.statusCode = 201; // Created status code
        response.setJsonPayload({"message": "User signed up successfully"});
        check caller->respond(response);
    }
    
    resource function post login(http:Caller caller, http:Request req) returns error? {
        // Parse the JSON payload from the request body
        json loginPayload = check req.getJsonPayload();
        
        // Log the received payload for debugging
        log:printInfo(loginPayload.toString());
        
        // Convert JSON to LoginRequest type
        LoginRequest loginDetails = check loginPayload.cloneWithType(LoginRequest);
        
        // Check if the user exists with the provided credentials
        map<json> filter = {
            "username": loginDetails.username,
            "password": loginDetails.password
        };
        
        stream<User, error?> userStream = check self.userCollection->find(filter);
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
        
        // Generate JWT token 
        string token = check self.generateJwtToken(user);
        
        // Create login response
        LoginResponse loginResponse = {
            token: token,
            username: user.username,
            name: user.name,        // Include name in response
            isadmin: user.isadmin,
            role: user.role
        };

        json loginResponseJson = loginResponse.toJson();
        
        // Send the response with the JWT token
        http:Response response = new;
        response.setJsonPayload(loginResponseJson);
        check caller->respond(response);
    }
    
    // New endpoint to handle Google login
    resource function post googleLogin(http:Caller caller, http:Request req) returns error? {
        // Parse the JSON payload from the request body
        json googleLoginPayload = check req.getJsonPayload();
        
        // Log the received payload for debugging
        log:printInfo(googleLoginPayload.toString());
        
        // Convert JSON to GoogleLoginRequest type
        GoogleLoginRequest googleDetails = check googleLoginPayload.cloneWithType(GoogleLoginRequest);
        
        // Check if the user exists with the provided Google ID
        map<json> filter = {"googleid": googleDetails.googleid};
        stream<User, error?> userStream = check self.userCollection->find(filter);
        record {|User value;|}? userRecord = check userStream.next();
        
        User user;
        
        if (userRecord is ()) {
            // User doesn't exist - create a new account
            user = {
                username: googleDetails.email, // Using email as username
                name: googleDetails.name,      // Use the name from Google account
                password: uuid:createType1AsString(), // Generate random password for security
                googleid: googleDetails.googleid,
                profile_pic: googleDetails.picture
            };
            
            // Insert the new user into the MongoDB collection
            check self.userCollection->insertOne(user);
            log:printInfo("New user created from Google login: " + googleDetails.email);
        } else {
            // User exists
            user = userRecord.value;
            log:printInfo("Existing user logged in via Google: " + user.username);
        }
        
        // Generate JWT token
        string token = check self.generateJwtToken(user);
        
        // Create login response
        LoginResponse loginResponse = {
            token: token,
            username: user.username,
            name: user.name,        // Include name in response
            isadmin: user.isadmin,
            role: user.role
        };

        json loginResponseJson = loginResponse.toJson();
        
        // Send the response with the JWT token
        http:Response response = new;
        response.setJsonPayload(loginResponseJson);
        check caller->respond(response);
    }
    
    // Initiate Google OAuth flow
    resource function get google() returns http:Response|error {
        // Fixed URL encoding by adding charset parameter
        string encodedRedirectUri = check url:encode(googleRedirectUri, "UTF-8");
        string authUrl = string `https://accounts.google.com/o/oauth2/v2/auth?client_id=${googleClientId}&response_type=code&scope=email%20profile&redirect_uri=${encodedRedirectUri}&access_type=offline`;
        
        // Create a redirect response
        http:Response response = new;
        response.statusCode = 302; // Found/Redirect status code
        response.setHeader("Location", authUrl);
        return response;
    }
    
    // Google OAuth callback endpoint
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
        
        // Get user profile information
        http:Client googleUserClient = check new ("https://www.googleapis.com");
        
        // Fix: Updated to use correct HTTP client GET method syntax
        map<string|string[]> headers = {"Authorization": "Bearer " + accessToken};
        http:Response userInfoResponse = check googleUserClient->get("/oauth2/v1/userinfo", headers);
        
        json userInfo = check userInfoResponse.getJsonPayload();
        
        string googleId = check userInfo.id;
        string email = check userInfo.email;
        string name = check userInfo.name;  // Get user's name from Google profile
        string? picture = check userInfo.picture;
        
        // Check if user already exists with this Google ID
        map<json> filter = {"googleid": googleId};
        stream<User, error?> userStream = check self.userCollection->find(filter);
        record {|User value;|}? userRecord = check userStream.next();
        
        User user;
        
        if (userRecord is ()) {
            // Create a new user
            user = {
                username: email,
                name: name,  // Use the name from Google profile
                password: uuid:createType1AsString(), // Generate random password
                googleid: googleId,
                profile_pic: picture is string ? picture : ""
            };
            
            check self.userCollection->insertOne(user);
        } else {
            user = userRecord.value;
        }
        
        // Generate JWT token
        string token = check self.generateJwtToken(user);
        
        // Create HTML response with the token
        string htmlResponse = string `
        <!DOCTYPE html>
        <html>
        <head>
            <title>Login Successful</title>
            <script>
                // Store the token and redirect
                localStorage.setItem('auth_token', '${token}');
                localStorage.setItem('username', '${user.username}');
                localStorage.setItem('name', '${user.name}');  // Store user's name
                localStorage.setItem('isadmin', '${user.isadmin}');
                localStorage.setItem('role', '${user.role}');
                window.location.href = '/dashboard'; // Redirect to your application's dashboard
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
        check caller->respond(response);
    }

    // Helper method to generate JWT token
    function generateJwtToken(User user) returns string|error {
        jwt:IssuerConfig issuerConfig = {
            username: user.username,
            issuer: "automeet",
            audience: ["automeet-app"],
            expTime: <decimal>time:utcNow()[0] + 3600, // Token valid for 1 hour
            signatureConfig: {
                algorithm: jwt:HS256,
                config: JWT_SECRET
            },
            customClaims: {
                "name": user.name,      // Include name in JWT token
                "isadmin": user.isadmin,
                "role": user.role
            }
        };
        
        string|jwt:Error token = jwt:issue(issuerConfig);
        
        if (token is jwt:Error) {
            log:printError("Error generating JWT token", token);
            return error("Error generating authentication token");
        }
        
        return token;
    }
}