import ballerina/http;
import ballerina/jwt;
import ballerina/log;
import ballerina/time;
import ballerina/uuid;
import ballerinax/mongodb;

// MongoDB Client Configuration with updated connection parameters
mongodb:Client mongoDb = check new ({
    connection: "mongodb+srv://pabasara:20020706@mycluster.cb3avmr.mongodb.net/?retryWrites=true&w=majority&appName=mycluster"
});

// JWT Configuration
// final string & readonly JWT_SECRET = "123";
final string & readonly JWT_SECRET = "6be1b0ba9fd7c089e3f8ce1bdfcd97613bbe986cf45c1eaec198108bad119bcbfe2088b317efb7d30bae8e60f19311ff13b8990bae0c80b4cb5333c26abcd27190d82b3cd999c9937647708857996bb8b836ee4ff65a31427d1d2c5c59ec67cb7ec94ae34007affc2722e39e7aaca590219ce19cec690ffb7846ed8787296fd679a5a2eadb7d638dc656917f837083a9c0b50deda759d453b8c9a7a4bb41ae077d169de468ec225f7ba21d04219878cd79c9329ea8c29ce8531796a9cc01dd200bb683f98585b0f98cffbf67cf8bafabb8a2803d43d67537298e4bf78c1a05a76342a44b2cf7cf3ae52b78469681b47686352122f8f1af2427985ec72783c06e";


// User Type Definition
type User record {|
    string id;
    string name;
    string email;
    string password;
    string? profileImage = ();
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

type chatroomresponse record {|
    string profileurl;
    string name;
    string lastMessage;
    string lastMessageTime;
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
    string status = "sent"; // Default value
|};

// Chat list response type
type ChatListEntry record {|
    int id;
    string sender;
    string avatar;
    string message;
    string time;
    boolean isTeam;
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
        self.usercollection = check self.automeetDb->getCollection("user");

        log:printInfo("MongoDB connection successful!");
    }

    // New endpoint to handle combined payload
    resource function post send(@http:Header {name: "Authorization"} string authHeader, @http:Payload json rawPayload) returns json|error {
        log:printInfo("Received combined chat payload");
        log:printDebug("Raw payload: " + rawPayload.toString());

        // Extract username from JWT token
        string? username = check self.validateAndGetUsername(authHeader);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }

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

        // MODIFIED: Use participants directly from the payload without auto-adding the creator
        Participant[] allParticipants = payload.participants;

        // 1. Create/Get ChatRoom
        string roomId = uuid:createType1AsString();
        boolean newRoomCreated = false;

        // Try to find an existing chatroom with exactly the same participants
        stream<record {}, error?> existingRoomsStream = check self.chatroomcollection->find({}, {});
        ChatRoom[] existingRooms = [];

        check from record {} room in existingRoomsStream
            do {
                ChatRoom|error chatRoom = room.cloneWithType(ChatRoom);
                if chatRoom is ChatRoom {
                    existingRooms.push(chatRoom);
                } else {
                    log:printError("Error converting room", chatRoom);
                }
            };

        // Check if there's an exact match of participants
        boolean foundMatch = false;
        foreach ChatRoom room in existingRooms {
            if room.participants.length() == allParticipants.length() {
                boolean allMatched = true;
                // Get all usernames from the room
                string[] roomUsernames = [];
                foreach Participant p in room.participants {
                    roomUsernames.push(p.username);
                }

                // Check if all participants are in the room
                foreach Participant p in allParticipants {
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
                participants: allParticipants,
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
    resource function get chatrooms(@http:Header {name: "Authorization"} string authHeader) returns json|error {
        log:printInfo("Fetching all chat rooms");
        // Extract username from JWT token
        string? username = check self.validateAndGetUsername(authHeader);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }

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
            return {"error": "Chat room not found"};
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

    // NEW ENDPOINT: Get chat list for logged-in user
    // Fixed get chatlist endpoint
    resource function get chatlist(@http:Header {name: "Authorization"} string authHeader) returns json|error {
        log:printInfo("Fetching chat list for logged-in user");

        // Extract username from JWT token
        string? username = check self.validateAndGetUsername(authHeader);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }

        // Find all chat rooms where the logged-in user is a participant
        stream<record {}, error?> chatRoomsStream = check self.chatroomcollection->find(
        {"participants.username": username},
        {}
        );

        // Create array to hold the formatted chat list with timestamps for sorting
        record {|
            int tempId;
            string lastMsgTimestamp;
            ChatListEntry entry;
        |}[] chatEntries = [];

        int tempCounter = 1;

        // Process each chatroom
        check from record {} room in chatRoomsStream
            do {
                // Convert raw document to ChatRoom type
                ChatRoom|error chatRoom = room.cloneWithType(ChatRoom);

                if chatRoom is ChatRoom {
                    // Get the most recent message for this chat room
                    record {|
                        string content;
                        string senderId;
                        string senddate;
                        string sendtime;
                    |}? latestMessage = check self.messagecollection->findOne(
                    {roomId: chatRoom.id},
                    {
                        projection: {content: 1, senderId: 1, senddate: 1, sendtime: 1, _id: 0},
                        sort: {senddate: -1, sendtime: -1}
                    }
                    );

                    if latestMessage is () {
                        // Skip rooms with no messages - use continue instead of return
                        continue;
                    }

                    // Format message time according to requirements
                    string formattedTime = "";
                    string sortableTimestamp = "";

                    // Parse date from the message
                    time:Civil msgDate = check time:civilFromString(latestMessage.senddate);
                    time:Civil today = check time:civilFromString(time:utcToString(time:utcNow()).substring(0, 10));

                    // Calculate if message is from today, yesterday, or earlier
                    int dayDiff = time:daysFrom(msgDate.year, msgDate.month, msgDate.day) -
                            time:daysFrom(today.year, today.month, today.day);

                    if dayDiff == 0 {
                        // If today, show time (HH:MM AM/PM)
                        string[] timeParts = latestMessage.sendtime.split(":");
                        int hour = check int:fromString(timeParts[0]);
                        string minute = timeParts[1];
                        string ampm = hour >= 12 ? "PM" : "AM";
                        hour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
                        formattedTime = string `${hour}:${minute} ${ampm}`;
                    } else if dayDiff == -1 {
                        // If yesterday
                        formattedTime = "Yesterday";
                    } else {
                        // String[] months was missing quotes around month names
                        string[] months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
                        formattedTime = string `${months[msgDate.month - 1]} ${msgDate.day}`;
                    }

                    // Create a sortable timestamp (for ordering messages by recency)
                    sortableTimestamp = string `${latestMessage.senddate} ${latestMessage.sendtime}`;

                    // Handle participant info based on count
                    boolean isTeam = chatRoom.participants.length() > 2;
                    string otherName = "";
                    string otherProfileUrl = "/profile.png"; // Default profile image

                    if chatRoom.participants.length() == 2 {
                        // Find the other participant (not the logged-in user)
                        foreach var participant in chatRoom.participants {
                            if participant.username != username {
                                // Get other user's details - the USER collection field names were incorrect
                                record {|string name; string? profileImage;|}? otherUser = check self.usercollection->findOne(
                                {email: participant.username},  // Changed username to email based on User record type
                                {projection: {name: 1, profileImage: 1, _id: 0}}
                                );

                                if otherUser is record {|string name; string? profileImage;|} {
                                    otherName = otherUser.name;
                                    // Use the profile image if available, otherwise keep default
                                    if otherUser.profileImage is string {
                                        otherProfileUrl = <string>otherUser.profileImage;
                                    }
                                }
                                break;
                            }
                        }
                    } else {
                        // For group chats, use a dynamic group name
                        string[] participantNames = [];
                        int count = 0;
                        foreach var participant in chatRoom.participants {
                            if count < 2 && participant.username != username {
                                record {|string name;|}? user = check self.usercollection->findOne(
                                {email: participant.username},
                                {projection: {name: 1, _id: 0}}
                                );
                                if user is record {|string name;|} {
                                    participantNames.push(user.name);
                                }
                                count += 1;
                            }
                        }

                        if participantNames.length() > 0 {
                            otherName = string:'join(" & ", ...participantNames);
                            if chatRoom.participants.length() > 3 {
                                otherName += string ` & ${chatRoom.participants.length() - 3} others`;
                            }
                        } else {
                            otherName = "Group Chat"; // Fallback name
                        }
                    }

                    // Create the chat list entry
                    ChatListEntry chatEntry = {
                        id: tempCounter,
                        sender: otherName,
                        avatar: otherProfileUrl, // Always provide an avatar
                        message: latestMessage.content,
                        time: formattedTime,
                        isTeam: isTeam
                    };

                    // Add to array with timestamp for sorting
                    chatEntries.push({
                        tempId: tempCounter,
                        lastMsgTimestamp: sortableTimestamp,
                        entry: chatEntry
                    });
                    tempCounter += 1;
                }
            };

        // Sort chat entries by timestamp (most recent first)
        chatEntries.sort(function(record {|int tempId; string lastMsgTimestamp; ChatListEntry entry;|} a,
                record {|int tempId; string lastMsgTimestamp; ChatListEntry entry;|} b) returns int {
            return a.lastMsgTimestamp > b.lastMsgTimestamp ? -1 : 1;
        });

        // Create final array
        ChatListEntry[] sortedChatList = [];
        int idCounter = 1;
        foreach var chatData in chatEntries {
            chatData.entry.id = idCounter;
            sortedChatList.push(chatData.entry);
            idCounter += 1;
        }

        return sortedChatList.toJson();
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
                secret: JWT_SECRET // For HMAC based JWT
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
