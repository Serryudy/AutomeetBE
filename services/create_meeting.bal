import ballerina/http;
import ballerina/uuid;
import ballerinax/mongodb;
import ballerina/jwt;
import ballerina/log;
// import ballerina/time;

// MongoDB client configuration
mongodb:Client mongoDb = check new ({
    connection: "mongodb+srv://pabasara:20020706@mycluster.cb3avmr.mongodb.net/?retryWrites=true&w=majority&appName=mycluster"
});

// JWT secret 
final string & readonly JWT_SECRET = "6be1b0ba9fd7c089e3f8ce1bdfcd97613bbe986cf45c1eaec198108bad119bcbfe2088b317efb7d30bae8e60f19311ff13b8990bae0c80b4cb5333c26abcd27190d82b3cd999c9937647708857996bb8b836ee4ff65a31427d1d2c5c59ec67cb7ec94ae34007affc2722e39e7aaca590219ce19cec690ffb7846ed8787296fd679a5a2eadb7d638dc656917f837083a9c0b50deda759d453b8c9a7a4bb41ae077d169de468ec225f7ba21d04219878cd79c9329ea8c29ce8531796a9cc01dd200bb683f98585b0f98cffbf67cf8bafabb8a2803d43d67537298e4bf78c1a05a76342a44b2cf7cf3ae52b78469681b47686352122f8f1af2427985ec72783c06e";

// Enhanced Meeting Types
type MeetingType "direct" | "group" | "round_robin";

type MeetingAssignment record {
    string id;
    string userId;
    string meetingId;
    boolean isAdmin;
};

type MeetingParticipant record {
    string userId;
    string access = "pending"; // can be "pending", "accepted", "declined"
};

type TimeSlot record {
    string startTime;
    string endTime;
};

type Meeting record {
    string id;
    string title;
    string location;
    MeetingType meetingType;
    
    // Common fields
    string description;
    string createdBy;
    string repeat = "none"; // can be "none", "daily", "weekly", "monthly", "yearly"
    
    // Type-specific fields - made optional
    TimeSlot? directTimeSlot?;
    TimeSlot[]? groupTimeSlots?;
    string? groupDuration?;
    
    TimeSlot[]? roundRobinTimeSlots?;
    string? roundRobinDuration?;
    MeetingParticipant[]? hosts?;
    MeetingParticipant[]? participants?;
};

type Contact record {
    string id;
    string username;
    string email;
    string phone;
    string userId;
};

type User record {
    string username;
    string password;
    string role = ""; 
    string phone_number = "";
    string profile_pic = "";
    string googleid = "";
};

type Group record {
    string id;
    string name;
    string[] contactIds;
    string createdBy;
};

type DirectMeetingRequest record {
    string title;
    string location;
    string description;
    TimeSlot directTimeSlot;
    string[] participantIds;
    string repeat = "none";
};

type GroupMeetingRequest record {
    string title;
    string location;
    string description;
    TimeSlot[] groupTimeSlots;
    string groupDuration;
    string[] participantIds;
    string repeat = "none";
};

type RoundRobinMeetingRequest record {
    string title;
    string location;
    string description;
    TimeSlot[] roundRobinTimeSlots;
    string roundRobinDuration;
    string[] hostIds;
    string[] participantIds;
    string repeat = "none";
};

// Error response record
type ErrorResponse record {
    string message;
    int statusCode;
};

@http:ServiceConfig {
    cors: {
        allowOrigins: ["http://localhost:3000"],
        allowCredentials: true,
        allowHeaders: ["content-type", "authorization"],
        allowMethods: ["POST", "GET", "OPTIONS", "PUT", "DELETE"],
        maxAge: 84900
    }
}
// Service definition
service /create on new http:Listener(8080) {
    mongodb:Database automeetDb;
    mongodb:Collection meetingCollection;
    mongodb:Collection contactCollection;
    mongodb:Collection userCollection;
    mongodb:Collection groupCollection;
    mongodb:Collection meetinguserCollection;
    
    function init() returns error? {
        self.automeetDb = check mongoDb->getDatabase("automeet");
        self.meetingCollection = check self.automeetDb->getCollection("meetings");
        self.contactCollection = check self.automeetDb->getCollection("contacts");
        self.userCollection = check self.automeetDb->getCollection("user");
        self.groupCollection = check self.automeetDb->getCollection("groups");
        self.meetinguserCollection = check self.automeetDb->getCollection("meetingusers");
    }
    
    // Endpoint to create a new meeting
    resource function post direct/meetings(@http:Header {name: "Authorization"} string authHeader, @http:Payload DirectMeetingRequest payload) returns Meeting|ErrorResponse|error {
        // Extract username from JWT token
        string? username = check self.validateAndGetUsername(authHeader);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Generate a unique meeting ID
        string meetingId = uuid:createType1AsString();
        
        // Process participants
        MeetingParticipant[] participants = check self.processParticipants(
            username, 
            payload.participantIds
        );
        
        // Create the meeting record
        Meeting meeting = {
            id: meetingId,
            title: payload.title,
            location: payload.location,
            meetingType: "direct",
            description: payload.description,
            createdBy: username,
            repeat: payload.repeat,
            directTimeSlot: payload.directTimeSlot,
            participants: participants
        };

        MeetingAssignment meetingAssignment = {
            id: uuid:createType1AsString(),
            userId: username,
            meetingId: meetingId,
            isAdmin: true
        };
        
        // Insert the meeting into MongoDB
        _ = check self.meetingCollection->insertOne(meeting);
        _ = check self.meetinguserCollection->insertOne(meetingAssignment);
        
        return meeting;
    }

    // Group Meeting Creation Endpoint
    resource function post group/meetings(@http:Header {name: "Authorization"} string authHeader, @http:Payload GroupMeetingRequest payload) returns Meeting|ErrorResponse|error {
        // Extract username from JWT token
        string? username = check self.validateAndGetUsername(authHeader);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Generate a unique meeting ID
        string meetingId = uuid:createType1AsString();

        // Process participants
        MeetingParticipant[] participants = check self.processParticipants(
            username, 
            payload.participantIds
        );
        
        // Create the meeting record
        Meeting meeting = {
            id: meetingId,
            title: payload.title,
            location: payload.location,
            meetingType: "group",
            description: payload.description,
            createdBy: username,
            repeat: payload.repeat,
            groupTimeSlots: payload.groupTimeSlots,
            groupDuration: payload.groupDuration,
            participants: participants
        };

        MeetingAssignment meetingAssignment = {
            id: uuid:createType1AsString(),
            userId: username,
            meetingId: meetingId,
            isAdmin: true
        };
        
        // Insert the meeting into MongoDB
        _ = check self.meetingCollection->insertOne(meeting);
        _ = check self.meetinguserCollection->insertOne(meetingAssignment);
        
        return meeting;
    }

    // Round Robin Meeting Creation Endpoint
    resource function post roundrobin/meetings(@http:Header {name: "Authorization"} string authHeader, @http:Payload RoundRobinMeetingRequest payload) returns Meeting|ErrorResponse|error {
        // Extract username from JWT token
        string? username = check self.validateAndGetUsername(authHeader);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Generate a unique meeting ID
        string meetingId = uuid:createType1AsString();
        
        // Process hosts
        MeetingParticipant[] hosts = check self.processHosts(
            username, 
            payload.hostIds
        );
        
        // Process participants
        MeetingParticipant[] participants = check self.processParticipants(
            username, 
            payload.participantIds
        );
        
        // Create the meeting record
        Meeting meeting = {
            id: meetingId,
            title: payload.title,
            location: payload.location,
            meetingType: "round_robin",
            description: payload.description,
            createdBy: username,
            repeat: payload.repeat,
            roundRobinTimeSlots: payload.roundRobinTimeSlots,
            roundRobinDuration: payload.roundRobinDuration,
            hosts: hosts,
            participants: participants
        };
        // Create meeting assignments for the meeting creator
        MeetingAssignment creatorAssignment = {
            id: uuid:createType1AsString(),
            userId: username,
            meetingId: meetingId,
            isAdmin: true
        };
        _ = check self.meetinguserCollection->insertOne(creatorAssignment);
        
        // Create meeting assignments for each host
        foreach MeetingParticipant host in hosts {
            MeetingAssignment hostAssignment = {
                id: uuid:createType1AsString(),
                userId: host.userId,
                meetingId: meetingId,
                isAdmin: true
            };
            _ = check self.meetinguserCollection->insertOne(hostAssignment);
        }
        
        // Insert the meeting into MongoDB
        _ = check self.meetingCollection->insertOne(meeting);
        
        return meeting;
    }
    function processHosts(string creatorUsername, string[] hostIds) returns MeetingParticipant[]|error {
        // If no hosts are provided, return an empty array
        if hostIds.length() == 0 {
            return [];
        }
        
        MeetingParticipant[] processedHosts = [];
        
        // Validate hosts from users collection
        foreach string hostId in hostIds {
            // Create a filter to find the user
            map<json> filter = {
                "username": hostId
            };
            
            // Query the users collection
            record {}|() user = check self.userCollection->findOne(filter);
            
            // If user not found, return an error
            if user is () {
                return error("Invalid host ID: Host must be a registered user");
            }
            
            processedHosts.push({
                userId: hostId,
                access: "accepted"  // Hosts always have accepted access
            });
        }
        
        // Ensure at least one host is processed
        if processedHosts.length() == 0 {
            return error("No valid hosts could be processed");
        }
        
        return processedHosts;
    }

    function processParticipants(string creatorUsername, string[] participantIds) returns MeetingParticipant[]|error {
        // If no participants are provided, return an empty array
        if participantIds.length() == 0 {
            return [];
        }
        
        MeetingParticipant[] processedParticipants = [];
        
        // Validate that all participants belong to the user's contacts
        foreach string participantId in participantIds {
            // Create a filter to find the contact
            map<json> filter = {
                "id": participantId,
                "userId": creatorUsername
            };
            
            // Query the contacts collection
            record {}|() contact = check self.contactCollection->findOne(filter);
            
            // If contact not found, return an error
            if contact is () {
                return error("Invalid participant ID: Participant must be in the user's contacts");
            }
            
            processedParticipants.push({
                userId: participantId,
                access: "pending"
            });
        }
        
        // Ensure at least one participant is processed
        if processedParticipants.length() == 0 {
            return error("No valid participants could be processed");
        }
        
        return processedParticipants;
    }

    // Endpoint to create a new group
    resource function post groups(@http:Header {name: "Authorization"} string authHeader, @http:Payload Group payload) returns Group|ErrorResponse|error {
        // Extract username from JWT token
        string? username = check self.validateAndGetUsername(authHeader);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        //asssign group to user
        payload.createdBy = username;

        // Generate a unique group ID if not provided
        if (payload.id == "") {
            payload.id = uuid:createType1AsString();
        }

        // Insert the group into MongoDB
        _ = check self.groupCollection->insertOne(payload);
        
        
        return payload;
    }

    // Endpoint to get groups for the authenticated user (for dropdown in UI)
    resource function get groups(@http:Header {name: "Authorization"} string authHeader) returns Group[]|ErrorResponse|error {
        // Extract username from JWT token
        string? username = check self.validateAndGetUsername(authHeader);
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
        stream<record {}, error?> groupCursor = check self.groupCollection->find(filter);
        Group[] groups = [];

        check from record{} groupData in groupCursor
            do {
                json groupJson = groupData.toJson();
                Group group = check groupJson.cloneWithType(Group);
                groups.push(group);
            };

        return groups;
    }

    // Endpoint to get every registered user
    resource function get users(@http:Header {name: "Authorization"} string authHeader) returns User[]|ErrorResponse|error {
        // Query the users collection
        stream<User, error?> contactCursor = check self.contactCollection->find();
        User[] users = [];
        
        // Process the results
        check from User user in contactCursor
            do {
                users.push(user);
            };
        
        return users;
    }

    // Endpoint to get users for the authenticated user (for dropdown in UI)
    resource function get contact/users(@http:Header {name: "Authorization"} string authHeader) returns User[]|ErrorResponse|error {
        // Extract username from JWT token
        string? username = check self.validateAndGetUsername(authHeader);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Create a filter to find contacts for this user
        map<json> contactFilter = {
            "userId": username
        };
        
        // Query the contacts collection
        stream<Contact, error?> contactCursor = check self.contactCollection->find(contactFilter);
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
        stream<record {}, error?> userCursor = check self.userCollection->find(userFilter);
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
    // Endpoint to get contacts for the authenticated user (for dropdown in UI)
    resource function get contacts(@http:Header {name: "Authorization"} string authHeader) returns Contact[]|ErrorResponse|error {
        // Extract username from JWT token
        string? username = check self.validateAndGetUsername(authHeader);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Create a filter to find contacts for this user
        map<json> filter = {
            "userId": username
        };
        
        // Query the contacts collection
        stream<Contact, error?> contactCursor = check self.contactCollection->find(filter);
        Contact[] contacts = [];
        
        // Process the results
        check from Contact contact in contactCursor
            do {
                contacts.push(contact);
            };
        
        return contacts;
    }
    
    // Endpoint to get all meetings for the authenticated user
    resource function get meetings(@http:Header {name: "Authorization"} string authHeader) returns Meeting[]|ErrorResponse|error {
        // Extract username from JWT token
        string? username = check self.validateAndGetUsername(authHeader);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Create a filter to find meetings created by this user
        map<json> filter = {
            "createdBy": username
        };
        
        // Query the meetings collection
        stream<record {}, error?> meetingCursor = check self.meetingCollection->find(filter);
        Meeting[] meetings = [];
        
        //Process the results
        check from record {} meetingData in meetingCursor
            do {
                // Convert record to json then map to Meeting type
                json jsonData = meetingData.toJson();
                Meeting meeting = check jsonData.cloneWithType(Meeting);
                meetings.push(meeting);
            };
    
        return meetings;
    }
    
    // Endpoint to get meeting details by ID
    resource function get meetings/[string meetingId](@http:Header {name: "Authorization"} string authHeader) returns Meeting|ErrorResponse|error {
        // Extract username from JWT token
        string? username = check self.validateAndGetUsername(authHeader);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Create a filter to find the meeting by ID
        map<json> filter = {
            "id": meetingId
        };
        
        // Query the meeting without specifying the return type
        record {}|() rawMeeting = check self.meetingCollection->findOne(filter);
        
        if rawMeeting is () {
            return {
                message: "Meeting not found",
                statusCode: 404
            };
        }
        
        // Convert the raw document to JSON then to Meeting type
        json jsonData = rawMeeting.toJson();
        Meeting meeting = check jsonData.cloneWithType(Meeting);
        
        
        return meeting;
    }
    
    // Function to validate that all contact IDs belong to the user
    function validateContactIds(string username, string[] contactIds) returns boolean|error {
        // Get all contacts for this user
        map<json> filter = {
            "userId": username
        };
        
        // Query the contacts collection
        stream<Contact, error?> contactCursor = check self.contactCollection->find(filter);
        string[] userContactIds = [];
        
        // Process the results to get all contact IDs for this user
        check from Contact contact in contactCursor
            do {
                userContactIds.push(contact.id);
            };
        
        // Check if all provided contact IDs are in the user's contacts
        // Fix: Replace 'includes' with a manual check function
        foreach string contactId in contactIds {
            boolean found = false;
            foreach string userContactId in userContactIds {
                if (userContactId == contactId) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                return false;
            }
        }
        
        return true;
    }
    
    // Endpoint to create a new contact
    resource function post contacts(@http:Header {name: "Authorization"} string authHeader, @http:Payload Contact payload) returns Contact|ErrorResponse|error {
        // Extract username from JWT token
        string? username = check self.validateAndGetUsername(authHeader);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }
        
        // Set the userId to the authenticated username
        payload.userId = username;
        
        // Generate a unique contact ID if not provided
        if (payload.id == "") {
            payload.id = uuid:createType1AsString();
        }
        
        // Insert the contact into MongoDB
        _ = check self.contactCollection->insertOne(payload);
        
        return payload;
    }

    // Helper function to validate JWT token and extract username - Fixed for JWT 2.13.0
    function validateAndGetUsername(string authHeader) returns string?|error {
        // Check if the Authorization header is present and properly formatted
        if (!authHeader.startsWith("Bearer ")) {
            log:printError("Invalid authorization header format");
            return ();
        }
        
        // Extract the token part
        string token = authHeader.substring(7);
        
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

    // Health check endpoint
    resource function get health() returns json {
        return {
            "status": "ok",
            "message": "Service is running"
        };
    }
}