import ballerina/http;
import ballerina/log;
import ballerina/jwt;
import mongodb_atlas_app.mongodb;

@http:ServiceConfig {
    cors: {
        allowOrigins: ["http://localhost:3000"],
        allowCredentials: true,
        allowHeaders: ["content-type", "authorization"],
        allowMethods: ["POST", "GET", "OPTIONS", "PUT", "DELETE"],
        maxAge: 84900
    }
}

service /api on new http:Listener(8080) {
    resource function put users/edit(http:Request req) returns User|ErrorResponse|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Parse the request payload
        json|http:ClientError jsonPayload = req.getJsonPayload();
        if jsonPayload is http:ClientError {
            return {
                message: "Invalid request payload: " + jsonPayload.message(),
                statusCode: 400
            };
        }
        
        // Create a filter to find the user
        map<json> filter = {
            "username": username
        };
        
        // Get current user data
        record {}|() userRecord = check mongodb:userCollection->findOne(filter);
        if userRecord is () {
            return {
                message: "User not found",
                statusCode: 404
            };
        }
        
        // Convert current user record to User type
        json userJson = userRecord.toJson();
        User currentUser = check userJson.cloneWithType(User);
        
        // Extract fields from payload for update
        map<json> updateFields = <map<json>>jsonPayload;
        map<json> updateOperations = {};
        
        // Update name if provided
        if updateFields.hasKey("name") {
            string nameValue = (updateFields["name"] ?: "").toString();
            updateOperations["name"] = nameValue;
            currentUser.name = nameValue;
        }
        
        // Update phone_number if provided
        if updateFields.hasKey("phone_number") {
            string phoneValue = (updateFields["phone_number"] ?: "").toString();
            updateOperations["phone_number"] = phoneValue;
            currentUser.phone_number = phoneValue;
        }
        
        // Update profile_pic if provided
        if updateFields.hasKey("profile_pic") {
            string picValue = (updateFields["profile_pic"] ?: "").toString();
            updateOperations["profile_pic"] = picValue;
            currentUser.profile_pic = picValue;
        }
        
        // Update bio if provided
        if updateFields.hasKey("bio") {
            string bioValue = (updateFields["bio"] ?: "").toString();
            updateOperations["bio"] = bioValue;
            currentUser.bio = bioValue;
        }
        
        // Update mobile_no if provided
        if updateFields.hasKey("mobile_no") {
            string mobileValue = (updateFields["mobile_no"] ?: "").toString();
            updateOperations["mobile_no"] = mobileValue;
            currentUser.mobile_no = mobileValue;
        }
        
        // Update time_zone if provided
        if updateFields.hasKey("time_zone") {
            string tzValue = (updateFields["time_zone"] ?: "").toString();
            updateOperations["time_zone"] = tzValue;
            currentUser.time_zone = tzValue;
        }
        
        // Update social_media if provided
        if updateFields.hasKey("social_media") {
            string socialValue = (updateFields["social_media"] ?: "").toString();
            updateOperations["social_media"] = socialValue;
            currentUser.social_media = socialValue;
        }
        
        // Update industry if provided
        if updateFields.hasKey("industry") {
            string industryValue = (updateFields["industry"] ?: "").toString();
            updateOperations["industry"] = industryValue;
            currentUser.industry = industryValue;
        }
        
        // Update company if provided
        if updateFields.hasKey("company") {
            string companyValue = (updateFields["company"] ?: "").toString();
            updateOperations["company"] = companyValue;
            currentUser.company = companyValue;
        }
        
        // Update is_available if provided
        if updateFields.hasKey("is_available") {
            json availableValue = updateFields["is_available"];
            boolean boolValue;
            
            if availableValue is boolean {
                boolValue = availableValue;
            } else {
                // Try to convert to boolean
                if availableValue.toString() == "true" {
                    boolValue = true;
                } else if availableValue.toString() == "false" {
                    boolValue = false;
                } else {
                    boolValue = true; // Default to true if conversion fails
                }
            }
            
            updateOperations["is_available"] = boolValue;
            currentUser.is_available = boolValue;
        }
        
        // If no editable fields were provided
        if updateOperations.length() == 0 {
            return {
                message: "No valid fields to update",
                statusCode: 400
            };
        }
        
        // Create update operation with proper MongoDB type
        mongodb:Update updateOperation = {
            "set": updateOperations
        };
        
        // Update user in database
        _ = check mongodb:userCollection->updateOne(filter, updateOperation);
        
        // Remove sensitive information before returning
        currentUser.password = "";
        
        return currentUser;
    }

    // get user with username given 
    resource function get users/[string usernameParam](http:Request req) returns User|ErrorResponse|error {
        // Extract username from cookie for authorization
        string? requestingUsername = check self.validateAndGetUsernameFromCookie(req);
        if requestingUsername is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Create a filter to find the requested user
        map<json> filter = {
            "username": usernameParam
        };
        
        // Get user data
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
        
        // Remove sensitive information
        user.password = "";
        
        // If not admin and not the same user, only return basic user profile info
        if requestingUsername != usernameParam && !user.isadmin {
            // Create a new User object with limited fields
            // Keep the required structure by creating a new User object
            User limitedUser = {
                username: user.username,
                name: user.name,
                password: "", // Required field but set to empty
                profile_pic: user.profile_pic,
                bio: user.bio,
                industry: user.industry,
                company: user.company,
                is_available: user.is_available,
                calendar_connected: user.calendar_connected,
                isadmin: false, // Set default values for other fields
                role: "",
                phone_number: "",
                googleid: "",
                mobile_no: "",
                time_zone: "",
                social_media: "",
                refresh_token: "",
                email_refresh_token: ""
            };
            
            return limitedUser;
        }
        
        // Return the full user record to the requesting user or admin
        return user;
    }

    resource function get users/profile(http:Request req) returns User|ErrorResponse|error {
        // Extract username from cookie
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Create a filter to find the user
        map<json> filter = {
            "username": username
        };
        
        // Get user data
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
        
        // Remove sensitive information
        user.password = "";
        
        return user;
    }

    // New helper function to extract JWT token from cookie
    public function validateAndGetUsernameFromCookie(http:Request request) returns string?|error {
        // Try to get the auth_token cookie
        http:Cookie[] cookies = request.getCookies();
        string? token = ();
        
        foreach http:Cookie cookie in cookies {
            if cookie.name == "auth_token" {
                token = cookie.value;
                break;
            }
        }
        
        // If no auth cookie found, check for Authorization header as fallback
        if token is () {
            string authHeader = check request.getHeader("Authorization");
            
            if authHeader.startsWith("Bearer ") {
                token = authHeader.substring(7);
            } else {
                log:printError("No authentication token found in cookies or headers");
                return ();
            }
        }
        
        // Validate the JWT token - Using updated structure for JWT 2.13.0
        jwt:ValidatorConfig validatorConfig = {
            issuer: "automeet",
            audience: "automeet-app",
            clockSkew: 60,
            signatureConfig: {
                secret: JWT_SECRET    // For HMAC based JWT
            }
        };
        
        jwt:Payload|error validationResult = jwt:validate(token, validatorConfig);
        
        if (validationResult is error) {
            log:printError("JWT validation failed", validationResult);
            return ();
        }
        
        jwt:Payload payload = validationResult;
        
        // First check if the username might be in the subject field
        if (payload.sub is string) {
            return payload.sub;
        }
        
        // Direct access to claim using index accessor
        var customClaims = payload["customClaims"];
        if (customClaims is map<json>) {
            var username = customClaims["username"];
            if (username is string) {
                return username;
            }
        }
        
        // Try to access username directly as a rest field
        var username = payload["username"];
        if (username is string) {
            return username;
        }
        
        log:printError("Username not found in JWT token");
        return ();
    }
    
}