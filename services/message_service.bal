import ballerinax/mongodb;
import ballerina/jwt;
import ballerina/http;
import ballerina/uuid;
import ballerina/time;
import ballerina/log;

// MongoDB Client Configuration with updated connection parameters
mongodb:Client mongoDb = check new ({
    connection: "mongodb+srv://pabasara:20020706@mycluster.cb3avmr.mongodb.net/?retryWrites=true&w=majority&appName=mycluster"
});

// JWT Configuration
final string & readonly JWT_SECRET = "123";


// User Type Definition
type User record {|
    string id;
    string name;
    string email;
    string password;
|};

// Updated: Changed userId to username and made it optional
type Participant record {|
    string username;
|};

// ChatRoom Type Definition
type ChatRoom record {|
    string id;
    Participant[] participants;
    boolean isActive;
    string createdAt;
|};

// Message Type Definition
type Message record {|
    string id;
    string roomId;
    string senderId;  // Keep as senderId for compatibility
    string content;
    string senddate;
    string sendtime;
    Attachment[]? attachments = ();
    string status;
|};

type Attachment record {|
    string 'type;
    string url;
    string name;
    int size;
|};

// Combined payload from UI with optional fields
type ChatPayload record {|
    Participant[] participants;
    string content;
    string senderId;
    Attachment[]? attachments = ();
    string status = "sent";  // Default value
|};

// Service definition
service /chat on new http:Listener(9090) {
    mongodb:Database automeetDb;
    mongodb:Collection chatroomcollection;
    mongodb:Collection messagecollection;
    mongodb:Collection usercollection;
    
    function init() returns error? {
        log:printInfo("Initializing chat service and connecting to MongoDB...");
        
        // Initialize the MongoDB database connection
        self.automeetDb = check mongoDb->getDatabase("automeet");
        self.chatroomcollection = check self.automeetDb->getCollection("chatrooms");
        self.messagecollection = check self.automeetDb->getCollection("messages");
        self.usercollection = check self.automeetDb->getCollection("users");
        
        log:printInfo("MongoDB connection successful!");
    }

    // New endpoint to handle combined payload
    resource function post send(@http:Payload json rawPayload) returns json|error {
        log:printInfo("Received combined chat payload");
        log:printDebug("Raw payload: " + rawPayload.toString());
        
        // Convert the raw JSON to the expected type with validation
        ChatPayload|error payload = rawPayload.cloneWithType(ChatPayload);
        
        if payload is error {
            log:printError("Payload conversion error", payload);
            return {
                "error": true,
                "message": "Invalid payload format",
                "details": payload.message()
            };
        }
        
        // Validate that participants array is not empty
        if payload.participants.length() == 0 {
            log:printError("Empty participants array");
            return {
                "error": true,
                "message": "Participants array cannot be empty"
            };
        }
        
        // 1. Create/Get ChatRoom
        string roomId = uuid:createType1AsString();
        boolean newRoomCreated = false;
        
        // Try to find an existing chatroom with exactly the same participants
        stream<record{}, error?> existingRoomsStream = check self.chatroomcollection->find({}, {});
        ChatRoom[] existingRooms = [];
        
        check from record {} room in existingRoomsStream
            do {
                existingRooms.push(<ChatRoom>room);
            };
        
        // Check if there's an exact match of participants
        boolean foundMatch = false;
        foreach ChatRoom room in existingRooms {
            if room.participants.length() == payload.participants.length() {
                boolean allMatched = true;
                // Get all usernames from the room
                string[] roomUsernames = [];
                foreach Participant p in room.participants {
                    roomUsernames.push(p.username);
                }
                
                // Check if all payload participants are in the room
                foreach Participant p in payload.participants {
                    int? index = roomUsernames.indexOf(p.username);
                    if index is () {
                        allMatched = false;
                        break;
                    }
                }
                
                if allMatched {
                    roomId = room.id;
                    foundMatch = true;
                    log:printInfo(string `Found existing chat room with ID: ${roomId}`);
                    break;
                }
            }
        }
        
        // If no matching room found, create a new one
        if !foundMatch {
            roomId = uuid:createType1AsString();
            
            ChatRoom newChatRoom = {
                id: roomId,
                participants: payload.participants,
                isActive: true,
                createdAt: time:utcNow().toString()
            };
            
            log:printInfo(string `Creating new chat room with ID: ${roomId}`);
            _ = check self.chatroomcollection->insertOne(newChatRoom);
            newRoomCreated = true;
        }
        
        // 2. Create Message
        string messageId = uuid:createType1AsString();
        time:Utc currentTime = time:utcNow();
        
        Message message = {
            id: messageId,
            roomId: roomId,
            senderId: payload.senderId,
            content: payload.content,
            senddate: time:utcToString(currentTime).substring(0, 10), // YYYY-MM-DD
            sendtime: time:utcToString(currentTime).substring(11, 19), // HH:MM:SS
            status: payload.status
        };
        
        // Add attachments if present
        if payload.attachments is Attachment[] {
            message.attachments = payload.attachments;
        }
        
        log:printInfo(string `Creating message with ID: ${messageId} for room: ${roomId}`);
        _ = check self.messagecollection->insertOne(message);
        
        // Return combined response
        return {
            "roomId": roomId,
            "messageId": messageId,
            "newRoomCreated": newRoomCreated
        };
    }

    // Get all chat rooms
    resource function get chatrooms() returns json|error {
        log:printInfo("Fetching all chat rooms");
        
        stream<ChatRoom, error?> chatRoomsStream = check self.chatroomcollection->find({}, {});
        ChatRoom[] chatRooms = [];
        
        check from ChatRoom chatRoom in chatRoomsStream
            do {
                chatRooms.push(chatRoom);
            };
            
        log:printInfo(string `Found ${chatRooms.length()} chat rooms`);
        return chatRooms.toJson();
    }
    
    // Get specific chat room by ID
    resource function get chatroom/[string roomId]() returns json|error {
        log:printInfo(string `Fetching chat room with ID: ${roomId}`);
        
        ChatRoom? chatRoom = check self.chatroomcollection->findOne({id: roomId}, {});
        if chatRoom is () {
            log:printError(string `Chat room not found with ID: ${roomId}`);
            return { "error": "Chat room not found" };
        }
        
        log:printInfo(string `Found chat room with ID: ${roomId}`);
        return chatRoom.toJson();
    }
    
    // Get messages for a specific chat room
    resource function get messages/[string roomId]() returns json|error {
        log:printInfo(string `Fetching messages for room: ${roomId}`);
        
        // Check if room exists
        ChatRoom? chatRoom = check self.chatroomcollection->findOne({id: roomId}, {});
        if chatRoom is () {
            log:printError(string `Chat room not found with ID: ${roomId}`);
            return error("Chat room not found");
        }
        
        stream<Message, error?> messagesStream = check self.messagecollection->find({roomId: roomId}, {});
        Message[] messages = [];
        
        check from Message message in messagesStream
            do {
                messages.push(message);
            };
            
        log:printInfo(string `Found ${messages.length()} messages for room ${roomId}`);
        return messages.toJson();
    }

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
}