import ballerina/http;
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

service /api/users on ln {
    resource function put edit(http:Request req) returns User|ErrorResponse|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
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
    resource function get [string usernameParam](http:Request req) returns User|ErrorResponse|error {
        // Extract username from cookie for authorization
        string? requestingUsername = check validateAndGetUsernameFromCookie(req);
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

    resource function get profile(http:Request req) returns User|ErrorResponse|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
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
    // serch users based on username
    resource function get search(http:Request req) returns User[]|ErrorResponse|error {
        // Extract username from cookie for authentication
        string? username = check validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }

        // Get query parameter
        string? searchQuery = req.getQueryParamValue("q");
        if searchQuery is () || searchQuery.trim().length() == 0 {
            return {
                message: "Search query is required",
                statusCode: 400
            };
        }

        // Create regex filter for case-insensitive partial matches
        map<json> filter = {
            "username": {
                "$regex": searchQuery,
                "$options": "i"  // case-insensitive
            }
        };

        // Find matching users
        stream<record {}, error?> userCursor = check mongodb:userCollection->find(filter);
        User[] users = [];

        // Process results
        check from record {} userData in userCursor
            do {
                json userJson = userData.toJson();
                User user = check userJson.cloneWithType(User);
                
                // Remove sensitive information
                user.password = "";
                user.refresh_token = "";
                user.email_refresh_token = "";
                
                // Only include basic profile information
                User limitedUser = {
                    username: user.username,
                    name: user.name,
                    password: "", // Required field but set empty
                    profile_pic: user.profile_pic,
                    bio: user.bio,
                    industry: user.industry,
                    company: user.company,
                    is_available: user.is_available,
                    calendar_connected: user.calendar_connected,
                    isadmin: false,
                    role: "",
                    phone_number: "",
                    googleid: "",
                    mobile_no: "",
                    time_zone: "",
                    social_media: "",
                    refresh_token: "",
                    email_refresh_token: ""
                };
                
                users.push(limitedUser);
            };

        return users;
    }
    
}