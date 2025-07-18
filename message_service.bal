import ballerina/websocket;
import ballerina/log;
import ballerina/uuid;
import ballerina/time;
import ballerina/http;
import ballerina/jwt;
import ballerina/lang.'string as strings;
import mongodb_atlas_app.mongodb;
import ballerina/lang.value;



// Type definition for webSocket message
type WSMessage record {|
    string _type;
    string roomId?;
    string? content = ();
    string? timestamp = ();
    map<json>? attachments = ();
    // Fields for room creation
    string[]? participants = ();
    string? roomName = ();
|};

// Participant type
type Participant record {|
    string username;
|};

// ChatRoom Type Definition
type ChatRoom record {|
    string id;
    Participant[] participants;
    boolean isActive;
    string createdAt;
    string? roomName = ();
|};

// Message Type Definition
type Message record {|
    string id;
    string roomId;
    string senderId;
    string content;
    string senddate;
    string sendtime;
    Attachment[]? attachments = ();
    string status;
|};

type Attachment record {|
    string _type;
    string url;
    string name;
    int size;
|};

type ChatRoomResponse record {|
    string id;
    string[] participants;
    boolean isActive;
    string createdAt;
    string? roomName;
|};


// Store active WebSocket connections
map<websocket:Caller> connections = {};
map<string[]> userRooms = {}; 
map<string> connectionUsers = {};

//JWT validation configurations
configurable string jwtIssuer = "automeet";
configurable string jwtAudience = "automeet-app";
configurable string jwtSigningKey = "6be1b0ba9fd7c089e3f8ce1bdfcd97613bbe986cf45c1eaec198108bad119bcbfe2088b317efb7d30bae8e60f19311ff13b8990bae0c80b4cb5333c26abcd27190d82b3cd999c9937647708857996bb8b836ee4ff65a31427d1d2c5c59ec67cb7ec94ae34007affc2722e39e7aaca590219ce19cec690ffb7846ed8787296fd679a5a2eadb7d638dc656917f837083a9c0b50deda759d453b8c9a7a4bb41ae077d169de468ec225f7ba21d04219878cd79c9329ea8c29ce8531796a9cc01dd200bb683f98585b0f98cffbf67cf8bafabb8a2803d43d67537298e4bf78c1a05a76342a44b2cf7cf3ae52b78469681b47686352122f8f1af2427985ec72783c06e";

// Create the WebSocket listener
listener websocket:Listener chatListener = new(9090);

// WebSocket service with authentication
service /ws/chat on chatListener {
    
    resource function get .(@http:Header {name: "Cookie"} string? cookieHeader) returns websocket:Service|websocket:UpgradeError {
        // Extract the authentication token from cookie
        if cookieHeader is () {
            return error websocket:UpgradeError("Unauthorized: Missing authentication cookie");
        }
        
        string? token = extractTokenFromCookie(cookieHeader);
        if token is () {
            return error websocket:UpgradeError("Unauthorized: Missing token in cookie");
        }
        
        // Validate token and extract userId
        string|error userId = validateAndGetUsernameFromToken(token);
        if userId is error {
            log:printError("Invalid authentication token", userId);
            return error websocket:UpgradeError("Unauthorized: Invalid authentication token");
        }
        
        log:printInfo(string `New WebSocket connection authenticated for user: ${userId}`);
        return new ChatSocketService(userId, mongodb:db, mongodb:chatroomCollection, mongodb:messageCollection);
    }
}


// WebSocket service class that handles individual connections
service class ChatSocketService {
    *websocket:Service;
    private final string userId;
    private final mongodb:Database db;
    private final mongodb:Collection chatroomCollection;
    private final mongodb:Collection messageCollection;
    
    function init(string userId, mongodb:Database automeetDb, 
                  mongodb:Collection chatroomCollection, 
                  mongodb:Collection messageCollection) {
        self.userId = userId;
        self.db = automeetDb;
        self.chatroomCollection = chatroomCollection;
        self.messageCollection = messageCollection;
        log:printInfo(string `Initializing chat service for user: ${userId}`);
    }

    remote function onOpen(websocket:Caller caller) returns error? {
        string connectionId = caller.getConnectionId();
        connections[connectionId] = caller;
        userRooms[connectionId] = [];
        connectionUsers[connectionId] = self.userId;
        
        log:printInfo(string `User ${self.userId} connected with WebSocket ID: ${connectionId}`);
        
        // Send connection acknowledgment
        check caller->writeMessage({
            "_type": "connected",
            "userId": self.userId,
            "timestamp": time:utcToString(time:utcNow())
        });
    }

    remote function onMessage(websocket:Caller caller, json|string|byte[] data) returns error? {
        string connectionId = caller.getConnectionId();
        websocket:Caller? userCaller = connections[connectionId];
        
        if userCaller is () {
            log:printError(string `No connection found for ID: ${connectionId}`);
            return;
        }
        
        // Handle different types of incoming data
        json jsonData;
        
        if data is string {
            // If client sent a string, try to parse it as JSON
            log:printInfo("Received string data: " + data);
            
            // Trim any leading/trailing whitespace
            string trimmedData = strings:trim(data);
            
            do {
                jsonData = check parseJsonString(trimmedData);
                log:printInfo("Successfully parsed string to JSON");
            } on fail error parseError {
                log:printError("Failed to parse string as JSON", parseError);
                check caller->writeMessage({
                    "_type": "error",
                    "content": "Invalid JSON format: " + parseError.message()
                });
                return;
            }
        } else if data is json {
            jsonData = data;
            log:printInfo("Received JSON data directly");
        } 
        
        // Try to parse the JSON to WSMessage
        WSMessage? parsedMessage = ();
        do {
            WSMessage message = check jsonData.cloneWithType(WSMessage);
            parsedMessage = message;
        } on fail error conversionError {
            log:printError("Failed to convert to WSMessage", conversionError);
            // Try a more flexible approach with a map
            if jsonData is map<json> {
                log:printInfo("Attempting manual message parsing");
                
                // Verify required field _type exists
                json? typeField = jsonData["_type"];
                if typeField is string {
                    // Create a WSMessage manually using the map entries
                    WSMessage message = {
                        _type: typeField
                    };
                    
                    // Add optional fields if they exist
                    if jsonData.hasKey("roomId") && jsonData["roomId"] is string {
                        message.roomId = <string>jsonData["roomId"];
                    }
                    
                    if jsonData.hasKey("content") && jsonData["content"] is string {
                        message.content = <string>jsonData["content"];
                    }
                    
                    if jsonData.hasKey("roomName") && jsonData["roomName"] is string {
                        message.roomName = <string>jsonData["roomName"];
                    }
                    
                    if jsonData.hasKey("participants") && jsonData["participants"] is json[] {
                        string[] participantsList = [];
                        json[] participantsJson = <json[]>jsonData["participants"];
                        
                        foreach json participant in participantsJson {
                            if participant is string {
                                participantsList.push(participant);
                            }
                        }
                        
                        message.participants = participantsList;
                    }
                    
                    if jsonData.hasKey("attachments") && jsonData["attachments"] is map<json> {
                        message.attachments = <map<json>>jsonData["attachments"];
                    }
                    
                    parsedMessage = message;
                } else {
                    check caller->writeMessage({
                        "_type": "error",
                        "content": "Message missing required '_type' field"
                    });
                    return;
                }
            } else {
                check caller->writeMessage({
                    "_type": "error",
                    "content": "Invalid message format: Not a valid JSON object"
                });
                return;
            }
        }
        
        if parsedMessage is WSMessage {
            // Process message based on type
            match parsedMessage._type {
                "create_room" => {
                    check self.handleCreateRoom(caller, parsedMessage);
                }
                "join_room" => {
                    check self.handleJoinRoom(caller, connectionId, parsedMessage.roomId ?: "");
                }
                "leave_room" => {
                    check self.handleLeaveRoom(caller, connectionId, parsedMessage.roomId ?: "");
                }
                "message" => {
                    check self.handleChatMessage(caller, connectionId, parsedMessage);
                }
                "typing" => {
                    check self.handleTypingNotification(caller, parsedMessage);
                }
                _ => {
                    log:printError(string `Unknown message type: ${parsedMessage._type}`);
                    check caller->writeMessage({
                        "_type": "error",
                        "content": "Unknown message type: " + parsedMessage._type
                    });
                }
            }
        } else {
            log:printError("Failed to parse message");
            check caller->writeMessage({
                "_type": "error",
                "content": "Invalid message format: Unable to parse"
            });
        }
    }

    remote function onClose(websocket:Caller caller, int statusCode, string reason) {
        string connectionId = caller.getConnectionId();
        
        // Clean up connections and room mappings
        _ = connections.remove(connectionId);
        _ = userRooms.remove(connectionId);
        _ = connectionUsers.remove(connectionId);
        
        log:printInfo(string `User ${self.userId} disconnected. Connection ID: ${connectionId}. Status code: ${statusCode}, reason: ${reason}`);
    }

    remote function onError(websocket:Caller caller, error err) {
        string connectionId = caller.getConnectionId();
        log:printError(string `Error in WebSocket connection ${connectionId}`, err);
    }

    // Handle new room creation
    function handleCreateRoom(websocket:Caller caller, WSMessage message) returns error? {
        string[]? participantsList = message.participants;
        
        // Check if participants list is null or empty
        if participantsList is () || participantsList.length() == 0 {
            check caller->writeMessage({
                "_type": "error",
                "content": "At least one participant is required to create a room"
            });
            return;
        }

        // Generate a new room ID
        string roomId = uuid:createType1AsString();
        time:Utc currentTime = time:utcNow();
        string timestamp = time:utcToString(currentTime);
        
        // Create participants array including the creator
        string[] allParticipants = participantsList;
        
        // Check if creator is already included, if not add them
        boolean creatorIncluded = false;
        foreach string participantId in allParticipants {
            if participantId == self.userId {
                creatorIncluded = true;
                break;
            }
        }
        
        if !creatorIncluded {
            allParticipants.push(self.userId);
        }
        
        // Convert string[] to Participant[]
        Participant[] participants = [];
        foreach string participantId in allParticipants {
            participants.push({username: participantId});
        }
        
        // Create the chat room record
        ChatRoom newRoom = {
            id: roomId,
            participants: participants,
            isActive: true,
            createdAt: timestamp,
            roomName: message.roomName
        };
        
        // Save to database with error handling
        do {
            _ = check self.chatroomCollection->insertOne(newRoom);
            log:printInfo(string `Room ${roomId} created and saved to database`);
        } on fail error dbError {
            log:printError("Database error while creating room", dbError);
            check caller->writeMessage({
                "_type": "error",
                "content": "Failed to create room: Database error"
            });
            return;
        }
        
        // Add room to creator's active rooms
        string connectionId = caller.getConnectionId();
        string[]? roomIds = userRooms[connectionId];
        
        if roomIds is () {
            userRooms[connectionId] = [roomId];
        } else {
            userRooms[connectionId] = [...roomIds, roomId];
        }
        
        // Notify the creator about successful room creation
        check caller->writeMessage({
            "_type": "room_created",
            "roomId": roomId,
            "participants": allParticipants,
            "roomName": message.roomName,
            "timestamp": timestamp
        });
        
        log:printInfo(string `User ${self.userId} created room ${roomId} with ${allParticipants.length()} participants`);
        
        // Notify other participants that they've been added to a new room
        foreach string participantId in allParticipants {
            if participantId != self.userId {
                // Find all connections for this user
                foreach string connId in connectionUsers.keys() {
                    if connectionUsers[connId] == participantId {
                        websocket:Caller? participantCaller = connections[connId];
                        if participantCaller is websocket:Caller {
                            check participantCaller->writeMessage({
                                "_type": "room_invitation",
                                "roomId": roomId,
                                "creatorId": self.userId,
                                "participants": allParticipants,
                                "roomName": message.roomName,
                                "timestamp": timestamp
                            });
                        }
                    }
                }
            }
        }
    }

    // Handle room join request
    function handleJoinRoom(websocket:Caller caller, string connectionId, string roomId) returns error? {
        // Check if the room exists
        boolean roomExists = check self.validateRoomAccess(self.userId, roomId);
        if !roomExists {
            check caller->writeMessage({
                "_type": "error",
                "content": "Room doesn't exist or you don't have access"
            });
            return;
        }
        
        // Update user's active rooms
        string[]? roomIds = userRooms[connectionId];
        string[] updatedRooms = [];
        
        if roomIds is () {
            updatedRooms = [roomId];
        } else {
            // Check if already in room
            boolean alreadyInRoom = false;
            foreach string id in roomIds {
                if id == roomId {
                    alreadyInRoom = true;
                    break;
                }
            }
            
            if !alreadyInRoom {
                updatedRooms = [...roomIds, roomId];
            } else {
                updatedRooms = roomIds;
            }
        }
        
        userRooms[connectionId] = updatedRooms;
        
        // Notify the user they've joined the room
        check caller->writeMessage({
            "_type": "room_joined",
            "roomId": roomId,
            "timestamp": time:utcToString(time:utcNow())
        });
        
        log:printInfo(string `User ${self.userId} joined room ${roomId}`);
    }

    // Handle room leave request
    function handleLeaveRoom(websocket:Caller caller, string connectionId, string roomId) returns error? {
        string[]? roomIds = userRooms[connectionId];
        
        if roomIds is string[] {
            string[] updatedRooms = [];
            
            // Create a new array without the specific roomId
            foreach string id in roomIds {
                if id != roomId {
                    updatedRooms.push(id);
                }
            }
            
            userRooms[connectionId] = updatedRooms;
            
            check caller->writeMessage({
                "_type": "room_left",
                "roomId": roomId,
                "timestamp": time:utcToString(time:utcNow())
            });
            
            log:printInfo(string `User ${self.userId} left room ${roomId}`);
        }
    }

    // Handle chat message (send new message)
    function handleChatMessage(websocket:Caller caller, string connectionId, WSMessage message) returns error? {
        if message.content is () || message.roomId is () || message.roomId == "" {
            check caller->writeMessage({
                "_type": "error",
                "content": "Invalid message: content or roomId missing"
            });
            return;
        }
        
        // Validate room access
        boolean roomAccess = check self.validateRoomAccess(self.userId, message.roomId ?: "");
        if !roomAccess {
            check caller->writeMessage({
                "_type": "error",
                "content": "You don't have access to this room"
            });
            return;
        }
        
        // Save message to database
        string messageId = uuid:createType1AsString();
        time:Utc currentTime = time:utcNow();
        
        Message dbMessage = {
            id: messageId,
            roomId: message.roomId ?: "",
            senderId: self.userId,
            content: message.content ?: "",
            senddate: time:utcToString(currentTime).substring(0, 10),
            sendtime: time:utcToString(currentTime).substring(11, 19),
            status: "sent"
        };
        
        // Add attachments if present
        if message.attachments is map<json> {
            // Process attachments with a more flexible approach
            Attachment[] attachments = [];
            map<json> attachmentsMap = <map<json>>message.attachments;
            
            foreach string key in attachmentsMap.keys() {
                json attachmentJson = attachmentsMap[key];
                
                if attachmentJson is map<json> {
                    map<json> attachmentMap = <map<json>>attachmentJson;
                    
                    // Check for required fields with safe type checking
                    string attachType = "";
                    string url = "";
                    string name = "";
                    int size = 0;
                    
                    if attachmentMap.hasKey("_type") && attachmentMap["_type"] is string {
                        attachType = <string>attachmentMap["_type"];
                    } else {
                        continue; // Skip this attachment
                    }
                    
                    if attachmentMap.hasKey("url") && attachmentMap["url"] is string {
                        url = <string>attachmentMap["url"];
                    } else {
                        continue;
                    }
                    
                    if attachmentMap.hasKey("name") && attachmentMap["name"] is string {
                        name = <string>attachmentMap["name"];
                    } else {
                        continue;
                    }
                    
                    if attachmentMap.hasKey("size") {
                        var sizeVal = attachmentMap["size"];
                        if sizeVal is int {
                            size = sizeVal;
                        } else if sizeVal is decimal {
                            size = <int>sizeVal;
                        } else if sizeVal is string {
                            // Try to parse string as int
                            do {
                                int|error intValue = 'int:fromString(<string>sizeVal);
                                if intValue is int {
                                    size = intValue;
                                }
                            } on fail {
                                size = 0;
                            }
                        }
                    }
                    
                    // Create attachment
                    Attachment attachment = {
                        _type: attachType,
                        url: url,
                        name: name,
                        size: size
                    };
                    
                    attachments.push(attachment);
                }
            }
            
            if attachments.length() > 0 {
                dbMessage.attachments = attachments;
            }
        }
        
        // Insert the message into the database with error handling
        do {
            _ = check self.messageCollection->insertOne(dbMessage);
            log:printInfo(string `Message saved to database: ${messageId}`);
        } on fail error dbError {
            log:printError("Database error while saving message", dbError);
            check caller->writeMessage({
                "_type": "error",
                "content": "Failed to save message"
            });
            return;
        }
        
        // Broadcast the message to all users in the room
        json broadcastMessage = {
            "_type": "new_message",
            "messageId": messageId,
            "roomId": message.roomId,
            "senderId": self.userId,
            "content": message.content,
            "timestamp": time:utcToString(currentTime),
            "attachments": message.attachments
        };
        
        check self.broadcastToRoom(message.roomId ?: "", broadcastMessage, connectionId);
        
        log:printInfo(string `Message from user ${self.userId} sent to room ${message.roomId ?: ""}`);
    }

    // Handle typing notification
    function handleTypingNotification(websocket:Caller caller, WSMessage message) returns error? {
        if message.roomId is () {
            return;
        }
        
        // Broadcast typing status to all users in the room
        json typingNotification = {
            "_type": "typing",
            "roomId": message.roomId,
            "senderId": self.userId,
            "timestamp": time:utcToString(time:utcNow())
        };
        
        check self.broadcastToRoom(message.roomId ?: "", typingNotification, caller.getConnectionId());
    }

    // Validate that a user has access to a specific room
    function validateRoomAccess(string userId, string roomId) returns boolean|error {
        // Get the chat room
        record{}|error|() result = self.chatroomCollection->findOne({id: roomId}, {});
        
        if result is error {
            log:printError("Database error while validating room access", result);
            return false;
        }
        
        if result is () {
            return false;
        }
        
        // Convert to ChatRoom type
        ChatRoom|error chatRoom = (<record{}>result).cloneWithType(ChatRoom);
        
        if chatRoom is error {
            log:printError("Error converting room data", chatRoom);
            return false;
        }
        
        // Check if the user is a participant
        foreach var participant in chatRoom.participants {
            if participant.username == userId {
                return true;
            }
        }
        
        return false;
    }

    // Broadcast a message to all users in a room
    function broadcastToRoom(string roomId, json message, string? excludeConnectionId = ()) returns error? {
        foreach string connId in connections.keys() {
            // Skip the sender if excludeConnectionId is specified
            if excludeConnectionId is string && connId == excludeConnectionId {
                continue;
            }
            
            string[]? roomIds = userRooms[connId];
            
            if roomIds is string[] {
                boolean inRoom = false;
                
                foreach string id in roomIds {
                    if id == roomId {
                        inRoom = true;
                        break;
                    }
                }
                
                if inRoom {
                    websocket:Caller userCaller = connections.get(connId);
                    check userCaller->writeMessage(message);
                }
            }
        }
    }
}

// Helper function to parse JSON string with error handling
function parseJsonString(string jsonStr) returns json|error {
    if jsonStr.length() == 0 {
        return error("Empty JSON string");
    }
    
    // Check if the string might be a JSON object or array
    string trimmed = strings:trim(jsonStr);
    if !(trimmed.startsWith("{") || trimmed.startsWith("[")) {
        return error("Invalid JSON format: Must start with { or [");
    }
    
    // Parse JSON string - simplified approach
    do {
        return check value:fromJsonString(jsonStr);
    } on fail var e {
        return error("Error parsing JSON: " + e.toString());
    }
}

// Simple echo service for testing WebSocket connection
service /echo on chatListener {
    resource function get .() returns websocket:Service {
        return new EchoService();
    }
}

service class EchoService {
    *websocket:Service;
    
    remote function onOpen(websocket:Caller caller) returns error? {
        log:printInfo("Echo client connected: " + caller.getConnectionId());
        check caller->writeMessage("Connected to echo service");
    }
    
    remote function onMessage(websocket:Caller caller, json|string|byte[] data) returns error? {
        log:printInfo("Echo received: " + data.toString());
        check caller->writeMessage(data);
    }
}

// Response types for the API
type ApiResponse record {|
    boolean success;
    string message;
    json data?;
|};

// HTTP service for chat resources
@http:ServiceConfig {
    cors: {
        allowOrigins: ["http://localhost:3000", "http://localhost:8080"],
        allowCredentials: true,
        allowHeaders: ["Authorization", "Content-Type", "Cookie", "Access-Control-Allow-Origin"],
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        exposeHeaders: ["X-Custom-Header"],
        maxAge: 84900
    }
}
service /api/chat on ln {

    resource function get rooms(@http:Header {name: "Cookie"} string? cookieHeader) returns ApiResponse|error {
        // Extract and validate the token
        string userId = check validateUserFromCookie(cookieHeader);
        log:printInfo(string `Fetching chat rooms for user: ${userId}`);
        
        // Query the database for rooms where the user is a participant
        record{}[] rooms = [];
        stream<record{}, error?> resultStream = check mongodb:chatroomCollection->find({
            "participants.username": userId
        });
        
        check from record{} room in resultStream
            do {
                rooms.push(room);
            };
        
        // Convert to response format
        ChatRoomResponse[] roomResponses = [];
        foreach record{} roomRecord in rooms {
            // Convert to ChatRoom type first
            ChatRoom|error chatRoom = roomRecord.cloneWithType(ChatRoom);
            
            if chatRoom is error {
                log:printError("Error converting room data", chatRoom);
                continue;
            }
            
            // Extract participant usernames
            string[] participantUsernames = [];
            foreach Participant participant in chatRoom.participants {
                participantUsernames.push(participant.username);
            }
            
            // Create response object
            ChatRoomResponse roomResponse = {
                id: chatRoom.id,
                participants: participantUsernames,
                isActive: chatRoom.isActive,
                createdAt: chatRoom.createdAt,
                roomName: chatRoom.roomName
            };
            
            roomResponses.push(roomResponse);
        }
        
        return {
            success: true,
            message: string `Retrieved ${roomResponses.length()} chat rooms`,
            data: roomResponses
        };
    }
    

    // Fetch messages for a specific room
    resource function get rooms/[string roomId]/messages(
    @http:Header {name: "Cookie"} string? cookieHeader,
    int _limit = 50,
    int offset = 0,
    string? startDate = (),
    string? endDate = ()
) returns ApiResponse|error {
    // Extract and validate the token
    string userId = check validateUserFromCookie(cookieHeader);
    log:printInfo(string `Fetching messages for room ${roomId} for user: ${userId}`);
    
    // First, check if the user has access to this room
    boolean hasAccess = check validateRoomAccess(userId, roomId);
    
    if !hasAccess {
        return {
            success: false,
            message: "You don't have access to this room"
        };
    }
    
    // Prepare the query
    map<json> query = {
        "roomId": roomId
    };
    
    // Add date filters if provided
    if startDate is string && endDate is string {
        query["senddate"] = {
            "$gte": startDate,
            "$lte": endDate
        };
    } else if startDate is string {
        query["senddate"] = {
            "$gte": startDate
        };
    } else if endDate is string {
        query["senddate"] = {
            "$lte": endDate
        };
    }
    
    // Create FindOptions with correct type
    mongodb:FindOptions findOptions = {
        sort: {
            "senddate": -1, 
            "sendtime": -1
        },
        'limit: _limit,
        'skip: offset
    };
    
    // Query the database for messages in this room
    record{}[] messages = [];
    stream<record{}, error?> resultStream = check mongodb:messageCollection->find(
        query,
        findOptions
    );
    
    check from record{} message in resultStream
        do {
            messages.push(message);
        };
    
    // Convert to response format
    json[] messageResponses = [];
    foreach record{} messageRecord in messages {
        // Convert to Message type
        Message|error message = messageRecord.cloneWithType(Message);
        
        if message is error {
            log:printError("Error converting message data", message);
            continue;
        }
        
        // Create response object
        map<json> messageResponse = {
            "id": message.id,
            "roomId": message.roomId,
            "senderId": message.senderId,
            "content": message.content,
            "senddate": message.senddate,
            "sendtime": message.sendtime,
            "status": message.status
        };
        
        // Add attachments if present
        if message.attachments is Attachment[] {
            messageResponse["attachments"] = message.attachments;
        }
        
        messageResponses.push(messageResponse);
    }
    
    return {
        success: true,
        message: string `Retrieved ${messageResponses.length()} messages for room ${roomId}`,
        data: messageResponses
    };
}


    // Fetch chat room by ID
    resource function get rooms/[string roomId](
        @http:Header {name: "Cookie"} string? cookieHeader
    ) returns ApiResponse|error {
        // Extract and validate the token
        string userId = check validateUserFromCookie(cookieHeader);
        log:printInfo(string `Fetching room ${roomId} for user: ${userId}`);
        
        // Check if the user has access to this room
        boolean hasAccess = check validateRoomAccess(userId, roomId);
        
        if !hasAccess {
            return {
                success: false,
                message: "You don't have access to this room"
            };
        }
        
        // Query the database for the room
        record{}|error|() result = mongodb:chatroomCollection->findOne({id: roomId}, {});
        
        if result is error {
            log:printError("Database error when fetching room", result);
            return {
                success: false,
                message: "Failed to fetch room details"
            };
        }
        
        if result is () {
            return {
                success: false,
                message: "Room not found"
            };
        }
        
        // Convert to ChatRoom type
        ChatRoom|error chatRoom = (<record{}>result).cloneWithType(ChatRoom);
        
        if chatRoom is error {
            log:printError("Error converting room data", chatRoom);
            return {
                success: false,
                message: "Error processing room data"
            };
        }
        
        // Extract participant usernames
        string[] participantUsernames = [];
        foreach Participant participant in chatRoom.participants {
            participantUsernames.push(participant.username);
        }
        
        // Create response object
        ChatRoomResponse roomResponse = {
            id: chatRoom.id,
            participants: participantUsernames,
            isActive: chatRoom.isActive,
            createdAt: chatRoom.createdAt,
            roomName: chatRoom.roomName
        };
        
        return {
            success: true,
            message: "Room details retrieved successfully",
            data: roomResponse
        };
    }
}

// Helper function to validate user from cookie
function validateUserFromCookie(string? cookieHeader) returns string|error {
    if cookieHeader is () {
        return error("Unauthorized: Missing authentication cookie");
    }
    
    string? token = extractTokenFromCookie(cookieHeader);
    if token is () {
        return error("Unauthorized: Missing token in cookie");
    }
    
    // Validate token and extract userId
    return validateAndGetUsernameFromToken(token);
}

// Function to extract token from cookie - identical to WebSocket service function
function extractTokenFromCookie(string cookieHeader) returns string? {
    log:printInfo("Original cookie header: " + cookieHeader);
    
    string[] cookies = re`;\s*`.split(cookieHeader);
    foreach string cookie in cookies {
        log:printInfo("Processing cookie part: " + cookie);
        if cookie.startsWith("auth_token=") {
            string token = cookie.substring(11); // Remove "auth_token=" prefix
            log:printInfo("Extracted token: " + token.substring(0, int:min(20, token.length())) + "...");
            return token;
        }
    }
    
    // If we can't find "auth_token=", try with just the cookie value itself
    if cookieHeader.startsWith("auth_token=") {
        string token = cookieHeader.substring(11); // Remove "auth_token=" prefix
        log:printInfo("Extracted token from full header: " + token.substring(0, int:min(20, token.length())) + "...");
        return token;
    }
    
    log:printInfo("No token found in cookie");
    return ();
}
// Function to validate JWT token - identical to WebSocket service function
function validateAndGetUsernameFromToken(string token) returns string|error {
    log:printInfo("Validating token: " + token.substring(0, 20) + "...");
    
    jwt:ValidatorConfig validatorConfig = {
        issuer: jwtIssuer,
        audience: jwtAudience,
        signatureConfig: {
            secret: jwtSigningKey
        }
    };
    
    jwt:Payload|error payload = jwt:validate(token, validatorConfig);
    if payload is error {
        log:printError("JWT validation failed", payload);
        return error("JWT validation failed", payload);
    }
    
    log:printInfo("JWT token validated successfully");
    
    // Extract username from the JWT payload
    // First try the sub field
    string? usernameFromSub = ();
    if payload.sub is string {
        usernameFromSub = <string>payload.sub;
    }
    
    if usernameFromSub is string && usernameFromSub != "" {
        log:printInfo("Username from sub: " + usernameFromSub);
        return usernameFromSub;
    }
    
    // If sub is not available, try the username directly from payload
    var username = payload["username"];
    if username is string && username != "" {
        log:printInfo("Username from payload: " + username);
        return username;
    }
    
    log:printError("Username not found in token");
    return error("Username not found in token");
}

// Function to validate room access - similar to the one in WebSocket service
function validateRoomAccess(string userId, string roomId) returns boolean|error {
    // Get the chat room
    record{}|error|() result = mongodb:chatroomCollection->findOne({id: roomId}, {});
    
    if result is error {
        log:printError("Database error while validating room access", result);
        return false;
    }
    
    if result is () {
        return false;
    }
    
    // Convert to ChatRoom type
    ChatRoom|error chatRoom = (<record{}>result).cloneWithType(ChatRoom);
    
    if chatRoom is error {
        log:printError("Error converting room data", chatRoom);
        return false;
    }
    
    // Check if the user is a participant
    foreach var participant in chatRoom.participants {
        if participant.username == userId {
            return true;
        }
    }
    
    return false;
}