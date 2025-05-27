import ballerina/http;
import ballerina/uuid;
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

service /api/community on ln {
    resource function post groups(http:Request req) returns Group|ErrorResponse|error {
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

        map<json> groupMap = <map<json>>jsonPayload;

        // Generate a unique group ID if not provided
        if !groupMap.hasKey("id") || groupMap["id"] == "" {
            groupMap["id"] = uuid:createType1AsString();
        }

        groupMap["createdBy"] = username;
        
        Group payload = check groupMap.cloneWithType(Group);
        
        // Validate that all contact IDs belong to the authenticated user
        boolean areContactsValid = check validateContactIds(username, payload.contactIds);
        if (!areContactsValid) {
            return {
                message: "Invalid contact ID: One or more contacts do not belong to the user",
                statusCode: 400
            };
        }
        
        // Additional validation: Verify that the contacts exist and match the username
        foreach string contactId in payload.contactIds {
            // Create a filter to find the contact
            map<json> filter = {
                "id": contactId,
                "createdBy": username
            };
            
            record {}|() contact = check mongodb:contactCollection->findOne(filter);
            
            // If contact not found, return an error
            if contact is () {
                return {
                    message: "Invalid contact ID: Contact '" + contactId + "' not found in user's contacts",
                    statusCode: 400
                };
            }
            
            // Extract the contact's username to verify it exists
            json contactJson = (<record {}>contact).toJson();
            string? contactUsername = check contactJson.username.ensureType();
            
            if contactUsername is () || contactUsername == "" {
                return {
                    message: "Invalid contact: Contact '" + contactId + "' has no associated username",
                    statusCode: 400
                };
            }
        }

        // Insert the group into MongoDB
        _ = check mongodb:groupCollection->insertOne(payload);
        
        return payload;
    }

    // Updated endpoint to get groups with cookie authentication
    resource function get groups(http:Request req) returns Group[]|ErrorResponse|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }

        // Create a filter to find groups for this user
        map<json> filter = {
            "createdBy": username
        };

        // Query the groups collection
        stream<record {}, error?> groupCursor = check mongodb:groupCollection->find(filter);
        Group[] groups = [];

        check from record{} groupData in groupCursor
            do {
                json groupJson = groupData.toJson();
                Group group = check groupJson.cloneWithType(Group);
                groups.push(group);
            };

        return groups;
    }

    // Updated endpoint to get contact users with cookie authentication
    resource function get contact/users(http:Request req) returns User[]|ErrorResponse|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Create a filter to find contacts for this user
        map<json> contactFilter = {
            "createdBy": username
        };
        
        // Query the contacts collection
        stream<Contact, error?> contactCursor = check mongodb:contactCollection->find(contactFilter);
        Contact[] contacts = [];
        
        // Process the contacts
        check from Contact contact in contactCursor
            do {
                contacts.push(contact);
            };
        
        // Extract usernames from contacts
        string[] contactUsernames = contacts.map(contact => contact.username);
        
        // Filter users based on contact usernames
        map<json> userFilter = {
            "username": {
                "$in": contactUsernames
            }
        };
        
        // Query the users collection
        stream<record {}, error?> userCursor = check mongodb:userCollection->find(userFilter);
        User[] users = [];
        
        // Process the results
        check from record {} userData in userCursor
            do {
                // Convert record to json then map to User type
                json jsonData = userData.toJson();
                User user = check jsonData.cloneWithType(User);
                
                // remove sensitive information like password
                user.password = "";
                
                users.push(user);
            };
        
        return users;
    }

    // Updated endpoint to create a new contact with cookie authentication
    resource function post contacts(http:Request req) returns error|ErrorResponse|Contact {
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
        
        // First convert to a map<json> to handle missing fields
        map<json> contactMap = <map<json>>jsonPayload;
        
        // Set default values for required fields before conversion
        if !contactMap.hasKey("id") || contactMap["id"] == "" {
            contactMap["id"] = uuid:createType1AsString();
        }
        
        // Set the createdBy to the authenticated username
        contactMap["createdBy"] = username;
        
        // Now convert to Contact type
        Contact payload = check contactMap.cloneWithType(Contact);
        
        // Insert the contact into MongoDB
        _ = check mongodb:contactCollection->insertOne(payload);
        
        return payload;
    }
    // Updated endpoint to get contacts with cookie authentication
    resource function get contacts(http:Request req) returns Contact[]|ErrorResponse|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Create a filter to find contacts for this user
        map<json> filter = {
            "createdBy": username
        };
        
        // Query the contacts collection
        stream<Contact, error?> contactCursor = check mongodb:contactCollection->find(filter);
        Contact[] contacts = [];
        
        // Process the results
        check from Contact contact in contactCursor
            do {
                contacts.push(contact);
            };
        
        return contacts;
    }
}