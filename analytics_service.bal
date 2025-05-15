import ballerina/http;
import ballerina/log;
import ballerina/uuid;
import mongodb_atlas_app.mongodb;
import ballerina/time;
import ballerina/jwt;

// Updated Transcript record to store meeting transcripts with questions and answers
type Transcript record {
    string id;
    string meetingId;
    QuestionAnswer[] questionAnswers;
    string createdAt;
    string updatedAt;
};

// New QuestionAnswer record to store both questions and answers
type QuestionAnswer record {
    string question;
    string answer;
};

// Updated Request payload for creating a transcript
type TranscriptRequest record {
    string meetingId;
    QuestionAnswer[] questionAnswers;
};

// Error response
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
service /api on new http:Listener(8081) {
    
    // Create a new transcript - Explicitly specify ErrorResponse as the error type
    resource function post transcripts(http:Request req) returns Transcript|http:Response|error {
        // Extract username from cookie for authentication
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            http:Response response = new;
            response.statusCode = 401;
            response.setJsonPayload({
                message: "Unauthorized: Invalid or missing authentication token"
            });
            return response;
        }
        
        // Parse the request payload
        json|http:ClientError jsonPayload = req.getJsonPayload();
        if jsonPayload is http:ClientError {
            http:Response response = new;
            response.statusCode = 400;
            response.setJsonPayload({
                message: "Invalid request payload: " + jsonPayload.message()
            });
            return response;
        }
        
        TranscriptRequest payload = check jsonPayload.cloneWithType(TranscriptRequest);
        
        // Validate the required fields
        if payload.meetingId == "" {
            http:Response response = new;
            response.statusCode = 400;
            response.setJsonPayload({
                message: "Meeting ID is required"
            });
            return response;
        }
        
        if payload.questionAnswers.length() == 0 {
            http:Response response = new;
            response.statusCode = 400;
            response.setJsonPayload({
                message: "At least one question and answer pair is required"
            });
            return response;
        }
        
        // Check if the meeting exists
        map<json> meetingFilter = {
            "id": payload.meetingId
        };
        
        record {}|() meeting = check mongodb:meetingCollection->findOne(meetingFilter);
        if meeting is () {
            http:Response response = new;
            response.statusCode = 404;
            response.setJsonPayload({
                message: "Meeting not found"
            });
            return response;
        }
        
        // Convert to Meeting type and check permissions
        json meetingJson = meeting.toJson();
        map<json> meetingData = <map<json>>meetingJson;
        
        // Verify that the user has permission to access this meeting
        boolean hasPermission = false;
        
        // Check if user is the creator
        if meetingData.hasKey("createdBy") && meetingData["createdBy"].toString() == username {
            hasPermission = true;
        } else {
            // Check if user is a participant
            if meetingData.hasKey("participants") {
                json[] participantsJson = <json[]>meetingData["participants"];
                foreach json participantJson in participantsJson {
                    map<json> participant = <map<json>>participantJson;
                    if participant.hasKey("username") && participant["username"].toString() == username {
                        hasPermission = true;
                        break;
                    }
                }
            }
            
            // Check if user is a host
            if !hasPermission && meetingData.hasKey("hosts") {
                json[] hostsJson = <json[]>meetingData["hosts"];
                foreach json hostJson in hostsJson {
                    map<json> host = <map<json>>hostJson;
                    if host.hasKey("username") && host["username"].toString() == username {
                        hasPermission = true;
                        break;
                    }
                }
            }
        }
        
        if !hasPermission {
            http:Response response = new;
            response.statusCode = 403;
            response.setJsonPayload({
                message: "Unauthorized: You don't have permission to create a transcript for this meeting"
            });
            return response;
        }
        
        // Check if transcript already exists for this meeting
        map<json> transcriptFilter = {
            "meetingId": payload.meetingId
        };
        
        record {}|() existingTranscript = check mongodb:transcriptCollection->findOne(transcriptFilter);
        
        string currentTime = time:utcToString(time:utcNow());
        
        // If transcript exists, update it
        if existingTranscript is record {} {
            json existingJson = existingTranscript.toJson();
            Transcript existing = check existingJson.cloneWithType(Transcript);
            
            // Update the question-answer pairs - convert to json first to resolve type compatibility
            json qaJson = payload.questionAnswers.toJson();
            mongodb:Update updateDoc = {
                "set": {
                    "questionAnswers": qaJson,
                    "updatedAt": currentTime
                }
            };
            
            _ = check mongodb:transcriptCollection->updateOne(transcriptFilter, updateDoc);
            
            // Return the updated transcript
            existing.questionAnswers = payload.questionAnswers;
            existing.updatedAt = currentTime;
            return existing;
        }
        
        // Create a new transcript
        Transcript transcript = {
            id: uuid:createType1AsString(),
            meetingId: payload.meetingId,
            questionAnswers: payload.questionAnswers,
            createdAt: currentTime,
            updatedAt: currentTime
        };
        
        // Insert into MongoDB
        _ = check mongodb:transcriptCollection->insertOne(transcript);
        
        return transcript;
    }
    
    // Get transcript by meeting ID
    resource function get transcripts/[string meetingId](http:Request req) returns Transcript|http:Response|error {
        // Extract username from cookie for authentication
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            http:Response response = new;
            response.statusCode = 401;
            response.setJsonPayload({
                message: "Unauthorized: Invalid or missing authentication token"
            });
            return response;
        }
        
        // Check if the meeting exists
        map<json> meetingFilter = {
            "id": meetingId
        };
        
        record {}|() meeting = check mongodb:meetingCollection->findOne(meetingFilter);
        if meeting is () {
            http:Response response = new;
            response.statusCode = 404;
            response.setJsonPayload({
                message: "Meeting not found"
            });
            return response;
        }
        
        // Convert to JSON and check permissions
        json meetingJson = meeting.toJson();
        map<json> meetingData = <map<json>>meetingJson;
        
        // Verify that the user has permission to access this meeting
        boolean hasPermission = false;
        
        // Check if user is the creator
        if meetingData.hasKey("createdBy") && meetingData["createdBy"].toString() == username {
            hasPermission = true;
        } else {
            // Check if user is a participant
            if meetingData.hasKey("participants") {
                json[] participantsJson = <json[]>meetingData["participants"];
                foreach json participantJson in participantsJson {
                    map<json> participant = <map<json>>participantJson;
                    if participant.hasKey("username") && participant["username"].toString() == username {
                        hasPermission = true;
                        break;
                    }
                }
            }
            
            // Check if user is a host
            if !hasPermission && meetingData.hasKey("hosts") {
                json[] hostsJson = <json[]>meetingData["hosts"];
                foreach json hostJson in hostsJson {
                    map<json> host = <map<json>>hostJson;
                    if host.hasKey("username") && host["username"].toString() == username {
                        hasPermission = true;
                        break;
                    }
                }
            }
        }
        
        if !hasPermission {
            http:Response response = new;
            response.statusCode = 403;
            response.setJsonPayload({
                message: "Unauthorized: You don't have permission to access this transcript"
            });
            return response;
        }
        
        // Get the transcript
        map<json> transcriptFilter = {
            "meetingId": meetingId
        };
        
        record {}|() transcriptRecord = check mongodb:transcriptCollection->findOne(transcriptFilter);
        
        if transcriptRecord is () {
            http:Response response = new;
            response.statusCode = 404;
            response.setJsonPayload({
                message: "Transcript not found for this meeting"
            });
            return response;
        }
        
        // Convert to Transcript type and return
        json transcriptJson = transcriptRecord.toJson();
        Transcript transcript = check transcriptJson.cloneWithType(Transcript);
        
        return transcript;
    }
    
    // Get all transcripts for user's meetings
    resource function get transcripts(http:Request req) returns Transcript[]|http:Response|error {
        // Extract username from cookie for authentication
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            http:Response response = new;
            response.statusCode = 401;
            response.setJsonPayload({
                message: "Unauthorized: Invalid or missing authentication token"
            });
            return response;
        }
        
        // Get all meetings where user is a creator, participant, or host
        map<json> meetingFilter = {
            "$or": [
                {"createdBy": username},
                {"participants.username": username},
                {"hosts.username": username}
            ]
        };
        
        stream<record {}, error?> meetingsCursor = check mongodb:meetingCollection->find(meetingFilter);
        string[] meetingIds = [];
        
        // Process meetings to get IDs
        check from record {} meetingData in meetingsCursor
            do {
                json meetingJson = meetingData.toJson();
                map<json> meetingMap = <map<json>>meetingJson;
                if meetingMap.hasKey("id") {
                    meetingIds.push(meetingMap["id"].toString());
                }
            };
        
        // If no meetings found, return empty array
        if meetingIds.length() == 0 {
            return [];
        }
        
        // Get transcripts for these meeting IDs
        map<json> transcriptFilter = {
            "meetingId": {
                "$in": meetingIds
            }
        };
        
        stream<record {}, error?> transcriptsCursor = check mongodb:transcriptCollection->find(transcriptFilter);
        Transcript[] transcripts = [];
        
        // Process transcripts
        check from record {} transcriptData in transcriptsCursor
            do {
                json transcriptJson = transcriptData.toJson();
                Transcript transcript = check transcriptJson.cloneWithType(Transcript);
                transcripts.push(transcript);
            };
        
        return transcripts;
    }
    
    // Update a transcript
    resource function put transcripts/[string transcriptId](http:Request req) returns Transcript|http:Response|error {
        // Extract username from cookie for authentication
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            http:Response response = new;
            response.statusCode = 401;
            response.setJsonPayload({
                message: "Unauthorized: Invalid or missing authentication token"
            });
            return response;
        }
        
        // Parse the request payload
        json|http:ClientError jsonPayload = req.getJsonPayload();
        if jsonPayload is http:ClientError {
            http:Response response = new;
            response.statusCode = 400;
            response.setJsonPayload({
                message: "Invalid request payload: " + jsonPayload.message()
            });
            return response;
        }
        
        // Get the transcript first to verify it exists
        map<json> transcriptFilter = {
            "id": transcriptId
        };
        
        record {}|() transcriptRecord = check mongodb:transcriptCollection->findOne(transcriptFilter);
        if transcriptRecord is () {
            http:Response response = new;
            response.statusCode = 404;
            response.setJsonPayload({
                message: "Transcript not found"
            });
            return response;
        }
        
        // Convert to Transcript type
        json transcriptJson = transcriptRecord.toJson();
        Transcript transcript = check transcriptJson.cloneWithType(Transcript);
        
        // Get the associated meeting to check permissions
        map<json> meetingFilter = {
            "id": transcript.meetingId
        };
        
        record {}|() meeting = check mongodb:meetingCollection->findOne(meetingFilter);
        if meeting is () {
            http:Response response = new;
            response.statusCode = 404;
            response.setJsonPayload({
                message: "Associated meeting not found"
            });
            return response;
        }
        
        // Convert to map<json> and check permissions
        json meetingJson = meeting.toJson();
        map<json> meetingData = <map<json>>meetingJson;
        
        // Verify that the user has permission to update this transcript
        boolean hasPermission = false;
        
        // Check if user is the creator
        if meetingData.hasKey("createdBy") && meetingData["createdBy"].toString() == username {
            hasPermission = true;
        } else {
            // Check if user is a host
            if meetingData.hasKey("hosts") {
                json[] hostsJson = <json[]>meetingData["hosts"];
                foreach json hostJson in hostsJson {
                    map<json> host = <map<json>>hostJson;
                    if host.hasKey("username") && host["username"].toString() == username {
                        hasPermission = true;
                        break;
                    }
                }
            }
        }
        
        if !hasPermission {
            http:Response response = new;
            response.statusCode = 403;
            response.setJsonPayload({
                message: "Unauthorized: Only meeting creators and hosts can update transcripts"
            });
            return response;
        }
        
        // Extract and validate the updated questions and answers
        map<json> updatePayload = <map<json>>jsonPayload;
        
        if !updatePayload.hasKey("questionAnswers") {
            http:Response response = new;
            response.statusCode = 400;
            response.setJsonPayload({
                message: "Question-Answer pairs are required"
            });
            return response;
        }
        
        json questionAnswersJson = updatePayload["questionAnswers"];
        QuestionAnswer[] questionAnswers = [];
        
        if questionAnswersJson is json[] {
            foreach json qaJson in questionAnswersJson {
                if qaJson is map<json> {
                    QuestionAnswer qa = check qaJson.cloneWithType(QuestionAnswer);
                    questionAnswers.push(qa);
                }
            }
        } else {
            http:Response response = new;
            response.statusCode = 400;
            response.setJsonPayload({
                message: "questionAnswers must be an array of question-answer pairs"
            });
            return response;
        }
        
        if questionAnswers.length() == 0 {
            http:Response response = new;
            response.statusCode = 400;
            response.setJsonPayload({
                message: "At least one question-answer pair is required"
            });
            return response;
        }
        
        // Update the transcript
        string currentTime = time:utcToString(time:utcNow());
        
        // Convert to json to avoid type compatibility issues
        json qaJson = questionAnswers.toJson();
        mongodb:Update updateDoc = {
            "set": {
                "questionAnswers": qaJson,
                "updatedAt": currentTime
            }
        };
        
        _ = check mongodb:transcriptCollection->updateOne(transcriptFilter, updateDoc);
        
        // Return the updated transcript
        transcript.questionAnswers = questionAnswers;
        transcript.updatedAt = currentTime;
        
        return transcript;
    }
    
    // Delete a transcript
    resource function delete transcripts/[string transcriptId](http:Request req) returns json|http:Response|error {
        // Extract username from cookie for authentication
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            http:Response response = new;
            response.statusCode = 401;
            response.setJsonPayload({
                message: "Unauthorized: Invalid or missing authentication token"
            });
            return response;
        }
        
        // Get the transcript first to verify it exists
        map<json> transcriptFilter = {
            "id": transcriptId
        };
        
        record {}|() transcriptRecord = check mongodb:transcriptCollection->findOne(transcriptFilter);
        if transcriptRecord is () {
            http:Response response = new;
            response.statusCode = 404;
            response.setJsonPayload({
                message: "Transcript not found"
            });
            return response;
        }
        
        // Convert to Transcript type
        json transcriptJson = transcriptRecord.toJson();
        Transcript transcript = check transcriptJson.cloneWithType(Transcript);
        
        // Get the associated meeting to check permissions
        map<json> meetingFilter = {
            "id": transcript.meetingId
        };
        
        record {}|() meeting = check mongodb:meetingCollection->findOne(meetingFilter);
        if meeting is () {
            http:Response response = new;
            response.statusCode = 404;
            response.setJsonPayload({
                message: "Associated meeting not found"
            });
            return response;
        }
        
        // Convert to map<json> and check permissions
        json meetingJson = meeting.toJson();
        map<json> meetingData = <map<json>>meetingJson;
        
        // Verify that the user has permission to delete this transcript
        boolean hasPermission = false;
        
        // Only creators can delete transcripts
        if meetingData.hasKey("createdBy") && meetingData["createdBy"].toString() == username {
            hasPermission = true;
        }
        
        if !hasPermission {
            http:Response response = new;
            response.statusCode = 403;
            response.setJsonPayload({
                message: "Unauthorized: Only meeting creators can delete transcripts"
            });
            return response;
        }
        
        // Delete the transcript
        _ = check mongodb:transcriptCollection->deleteOne(transcriptFilter);
        
        return {
            "message": "Transcript deleted successfully",
            "transcriptId": transcriptId
        };
    }
    
    // New endpoint to get the standard meeting questions
    resource function get standard/questions() returns json|error {
        // Return the 10 standard questions
        return {
            "questions": [
                "What was the purpose of the meeting?",
                "What was the primary agenda of the meeting?",
                "Around how many participants actually contributed?",
                "Was the agenda fully covered? (Yes/No)",
                "If not, what topics were left out and why?",
                "Was the meeting conducted within the scheduled time? (Yes/No)",
                "If not, by how much time did it exceed or finish early?",
                "What were the key decisions made?",
                "Were there any unresolved issues?",
                "Did participants express satisfaction or dissatisfaction with the meeting's outcomes?"
            ]
        };
    }

    resource function post transcripts/[string meetingId]/generatereport(http:Request req) returns json|http:Response|error {
        // Authentication (same as your other endpoints)
        string? username = check self.validateAndGetUsernameFromCookie(req);
        if username is () {
            http:Response response = new;
            response.statusCode = 401;
            response.setJsonPayload({
                message: "Unauthorized: Invalid or missing authentication token"
            });
            return response;
        }
        
        // Check if the meeting exists and user has permission
        map<json> meetingFilter = {
            "id": meetingId
        };
        
        record {}|() meeting = check mongodb:meetingCollection->findOne(meetingFilter);
        if meeting is () {
            http:Response response = new;
            response.statusCode = 404;
            response.setJsonPayload({
                message: "Meeting not found"
            });
            return response;
        }
        
        // Convert to JSON and check permissions
        json meetingJson = meeting.toJson();
        map<json> meetingData = <map<json>>meetingJson;
        
        // Verify user permissions (similar to other endpoints)
        boolean hasPermission = false;
        
        // Check if user is the creator
        if meetingData.hasKey("createdBy") && meetingData["createdBy"].toString() == username {
            hasPermission = true;
        } else {
            // Check if user is a participant
            if meetingData.hasKey("participants") {
                json[] participantsJson = <json[]>meetingData["participants"];
                foreach json participantJson in participantsJson {
                    map<json> participant = <map<json>>participantJson;
                    if participant.hasKey("username") && participant["username"].toString() == username {
                        hasPermission = true;
                        break;
                    }
                }
            }
            
            // Check if user is a host
            if !hasPermission && meetingData.hasKey("hosts") {
                json[] hostsJson = <json[]>meetingData["hosts"];
                foreach json hostJson in hostsJson {
                    map<json> host = <map<json>>hostJson;
                    if host.hasKey("username") && host["username"].toString() == username {
                        hasPermission = true;
                        break;
                    }
                }
            }
        }
        
        if !hasPermission {
            http:Response response = new;
            response.statusCode = 403;
            response.setJsonPayload({
                message: "Unauthorized: You don't have permission to generate a report for this meeting"
            });
            return response;
        }
        
        // Get the transcript
        map<json> transcriptFilter = {
            "meetingId": meetingId
        };
        
        record {}|() transcriptRecord = check mongodb:transcriptCollection->findOne(transcriptFilter);
        if transcriptRecord is () {
            http:Response response = new;
            response.statusCode = 404;
            response.setJsonPayload({
                message: "Transcript not found for this meeting"
            });
            return response;
        }
        
        // Convert records to JSON
        json transcriptJson = transcriptRecord.toJson();
        
        // Prepare the report request payload
        json reportRequest = {
            "meeting": {
                "name": meetingData.hasKey("name") ? meetingData["name"].toString() : "Untitled Meeting",
                "date": meetingData.hasKey("scheduledDate") ? meetingData["scheduledDate"].toString() : 
                        (meetingData.hasKey("createdAt") ? meetingData["createdAt"].toString() : "N/A"),
                "time": meetingData.hasKey("scheduledTime") ? meetingData["scheduledTime"].toString() : "N/A",
                "location": meetingData.hasKey("location") ? meetingData["location"].toString() : "N/A",
                // Include additional meeting details that might be useful
                "createdBy": meetingData.hasKey("createdBy") ? meetingData["createdBy"].toString() : "N/A"
            },
            "transcript": transcriptJson
        };
        
        // Create HTTP client to call the report generator API
        http:Client reportClient = check new("http://localhost:8082");  // Update URL if deployed elsewhere
        
        // Call the report generator API
        http:Response|error reportResponse = check reportClient->post("/api/generate-report", reportRequest);
        
        if reportResponse is error {
            http:Response response = new;
            response.statusCode = 500;
            response.setJsonPayload({
                message: "Failed to generate report: " + reportResponse.message()
            });
            return response;
        }
        
        // Return the API response
        return reportResponse;
    }
    
    // Helper function to validate JWT token from cookie
    function validateAndGetUsernameFromCookie(http:Request request) returns string?|error {
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
        
        // Use the same JWT_SECRET as in the main service
        final string & readonly JWT_SECRET = "6be1b0ba9fd7c089e3f8ce1bdfcd97613bbe986cf45c1eaec198108bad119bcbfe2088b317efb7d30bae8e60f19311ff13b8990bae0c80b4cb5333c26abcd27190d82b3cd999c9937647708857996bb8b836ee4ff65a31427d1d2c5c59ec67cb7ec94ae34007affc2722e39e7aaca590219ce19cec690ffb7846ed8787296fd679a5a2eadb7d638dc656917f837083a9c0b50deda759d453b8c9a7a4bb41ae077d169de468ec225f7ba21d04219878cd79c9329ea8c29ce8531796a9cc01dd200bb683f98585b0f98cffbf67cf8bafabb8a2803d43d67537298e4bf78c1a05a76342a44b2cf7cf3ae52b78469681b47686352122f8f1af2427985ec72783c06e";
        
        // Validate the JWT token
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