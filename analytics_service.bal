import ballerina/http;
import ballerina/uuid;
import mongodb_atlas_app.mongodb;
import ballerina/time;
import ballerina/log;

configurable string hfApiKey = ?;

@http:ServiceConfig {
    cors: {
        allowOrigins: ["http://localhost:3000"],
        allowCredentials: true,
        allowHeaders: ["content-type", "authorization"],
        allowMethods: ["POST", "GET", "OPTIONS", "PUT", "DELETE"],
        maxAge: 84900
    }
}


service /api/analytics on ln {
    
    // Create a new transcript - Explicitly specify ErrorResponse as the error type
    resource function post transcripts(http:Request req) returns Transcript|http:Response|error {
        // Extract username from cookie for authentication
        string? username = check validateAndGetUsernameFromCookie(req);
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
        string? username = check validateAndGetUsernameFromCookie(req);
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
        string? username = check validateAndGetUsernameFromCookie(req);
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
        string? username = check validateAndGetUsernameFromCookie(req);
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
        string? username = check validateAndGetUsernameFromCookie(req);
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
    
    

    // Analytics endpoint
    resource function get meetings/[string meetingId]/analytics(http:Request req) returns MeetingAnalytics|ErrorResponse|error {
        // Extract username from cookie
        string? username = check validateAndGetUsernameFromCookie(req);
        if username is () {
            return {
                message: "Unauthorized: Invalid or missing authentication token",
                statusCode: 401
            };
        }

        // Verify meeting exists and user has access
        map<json> meetingFilter = {
            "id": meetingId
        };

        record {}|() meetingRecord = check mongodb:meetingCollection->findOne(meetingFilter);
        if meetingRecord is () {
            return {
                message: "Meeting not found",
                statusCode: 404
            };
        }

        json meetingJson = meetingRecord.toJson();
        Meeting meeting = check meetingJson.cloneWithType(Meeting);

        // Check user's permission
        boolean hasAccess = self.checkUserMeetingAccess(username, meeting);
        if !hasAccess {
            return {
                message: "You don't have access to this meeting's analytics",
                statusCode: 403
            };
        }

        // Generate or retrieve analytics
        MeetingAnalytics analytics = check self.generateMeetingAnalytics(meeting);
        return analytics;
    }

    // Helper function to generate meeting analytics
    function generateMeetingAnalytics(Meeting meeting) returns MeetingAnalytics|error {
        string[] daysOfWeek = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
        string currentTime = time:utcToString(time:utcNow());

        // Get rescheduling frequency
        DayFrequency[] reschedulingFreq = check self.calculateReschedulingFrequency(meeting.title);

        // Scheduling accuracy logic
        AccuracyMetric[]|string schedulingAccuracy;
        AccuracyMetric[] accuracyMetrics = [];
        
        if meeting.meetingType == "direct" {
            schedulingAccuracy = "not enough data";
        } else {
            // For group/round_robin, check if directTimeSlot exists
            if meeting?.directTimeSlot is TimeSlot {
                // TimeSlot confirmedSlot = meeting?.directTimeSlot ?: {startTime: "", endTime: ""};

                // Gather all availabilities for this meeting
                map<json> availFilter = { "meetingId": meeting.id };
                stream<record {}, error?> availCursor = check mongodb:availabilityCollection->find(availFilter);
                TimeSlot[] allSlots = [];

                check from record {} availData in availCursor
                    do {
                        json availJson = availData.toJson();
                        Availability avail = check availJson.cloneWithType(Availability);
                        allSlots = [...allSlots, ...avail.timeSlots];
                    };

                // Also gather participant availabilities
                stream<record {}, error?> partAvailCursor = check mongodb:participantAvailabilityCollection->find(availFilter);
                check from record {} partAvailData in partAvailCursor
                    do {
                        json partAvailJson = partAvailData.toJson();
                        ParticipantAvailability partAvail = check partAvailJson.cloneWithType(ParticipantAvailability);
                        allSlots = [...allSlots, ...partAvail.timeSlots];
                    };

                // Count how many slots fall on each day of the week
                map<int> dayCounts = {};
                foreach string day in daysOfWeek {
                    dayCounts[day] = 0;
                }
                
                foreach TimeSlot slot in allSlots {
                    time:Civil|error civil = time:civilFromString(slot.startTime);
                    if civil is time:Civil {
                        time:DayOfWeek? dow = civil.dayOfWeek;
                        if dow is time:DayOfWeek {
                            int idx = dow - 1;
                            if idx >= 0 && idx < daysOfWeek.length() {
                                string day = daysOfWeek[idx];
                                dayCounts[day] = (dayCounts[day] ?: 0) + 1;
                            }
                        }
                    }
                }

                // Find the best suited day (most available slots)
                int maxCount = 0;
                foreach string day in daysOfWeek {
                    int currentCount = dayCounts[day] ?: 0;
                    if currentCount > maxCount {
                        maxCount = currentCount;
                    }
                }

                // Assign a value between 0 and 1 for each day (relative to best day)
                foreach string day in daysOfWeek {
                    float value = maxCount > 0 ? (<float>(dayCounts[day] ?: 0)) / (<float>maxCount) : 0.0;
                    accuracyMetrics.push({
                        day: day,
                        accuracy: self.roundTo2Decimals(value)
                    });
                }
                schedulingAccuracy = accuracyMetrics;
            } else {
                schedulingAccuracy = "not enough data";
            }
        }

        // Get engagement metrics
        EngagementMetrics|string engagementResult = check self.getEngagementMetricsFromTranscript(meeting.id);
        
        EngagementMetrics engagement;
        if engagementResult is string {
            engagement = {
                speakingTime: 0.0,
                participantEngagement: 0.0,
                chatEngagement: 0.0
            };
        } else {
            engagement = engagementResult;
        }

        return {
            meetingId: meeting.id,
            reschedulingFrequency: reschedulingFreq,
            schedulingAccuracy: schedulingAccuracy,
            engagement: engagement,
            createdAt: currentTime,
            updatedAt: currentTime
        };
    }

    function getEngagementMetricsFromTranscript(string meetingId) returns string|EngagementMetrics|error {
        // Find the transcript for this meeting
        map<json> transcriptFilter = { "meetingId": meetingId };
        record {}|() transcriptRecord = checkpanic mongodb:transcriptCollection->findOne(transcriptFilter);

        if transcriptRecord is () {
            return "not enough data";
        }

        json transcriptJson = transcriptRecord.toJson();
        Transcript transcript = checkpanic transcriptJson.cloneWithType(Transcript);

        float? speakingTime = ();
        float? participantEngagement = ();
        float? chatEngagement = ();

        // Extract metrics from questionAnswers
        foreach QuestionAnswer qa in transcript.questionAnswers {
            match qa.question {
                "speaking time" => {
                    speakingTime = check float:fromString(qa.answer);
                }
                "participant engagement" => {
                    participantEngagement = check float:fromString(qa.answer);
                }
                "chat engagement" => {
                    chatEngagement = check float:fromString(qa.answer);
                }
            }
        }

        if speakingTime is float && participantEngagement is float && chatEngagement is float {
            return {
                speakingTime: self.roundTo2Decimals(speakingTime),
                participantEngagement: self.roundTo2Decimals(participantEngagement),
                chatEngagement: self.roundTo2Decimals(chatEngagement)
            };
        }
        
        return "not enough data";
    }

    // Helper function to calculate rescheduling frequency
    function calculateReschedulingFrequency(string meetingTitle) returns DayFrequency[]|error {
        string[] daysOfWeek = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
        
        // Find all meetings with the same title
        map<json> filter = {
            "title": meetingTitle
        };
        
        stream<record {}, error?> meetingCursor = check mongodb:meetingCollection->find(filter);
        map<int> dayFrequencyMap = {};
        
        // Process meetings
        int meetingCount = 0;
        check from record {} meetingData in meetingCursor
            do {
                meetingCount += 1;
                json meetingJson = meetingData.toJson();
                Meeting meeting = check meetingJson.cloneWithType(Meeting);
                
                // Extract day of week from meeting's directTimeSlot
                if meeting?.directTimeSlot is TimeSlot {
                    TimeSlot timeSlot = <TimeSlot>meeting?.directTimeSlot;
                    time:Civil|error dateTime = time:civilFromString(timeSlot.startTime);
                    if dateTime is time:Civil {
                        time:DayOfWeek? dayOfWeek = dateTime.dayOfWeek; // 1 (Monday) to 7 (Sunday)
                            if dayOfWeek is time:DayOfWeek {
                                string day = daysOfWeek[dayOfWeek - 1]; // Adjust index as array starts from 0
                        dayFrequencyMap[day] = (dayFrequencyMap[day] ?: 0) + 1;
                    }
                }
            }
            };
    
        DayFrequency[] frequencies = [];
        
        // If only one meeting found, return all zeros
        if meetingCount <= 1 {
            foreach string day in daysOfWeek {
                frequencies.push({
                    day: day,
                    frequency: 0
                });
            }
            return frequencies;
        }
        
        // Generate frequencies for each day
        foreach string day in daysOfWeek {
            frequencies.push({
                day: day,
                frequency: dayFrequencyMap[day] ?: 0 // Use 0 for days without meetings
            });
        }
        
        return frequencies;
    }

    // Helper function to round numbers to 2 decimal places
    function roundTo2Decimals(float number) returns float {
        return <float>(<int>(number * 100.0)) / 100.0;
    }

    // Helper function to check user's access to meeting
    function checkUserMeetingAccess(string username, Meeting meeting) returns boolean {
        if meeting.createdBy == username {
            return true;
        }
        
        if meeting?.participants is MeetingParticipant[] {
            foreach MeetingParticipant participant in meeting?.participants ?: [] {
                if participant.username == username {
                    return true;
                }
            }
        }
        
        if meeting?.hosts is MeetingParticipant[] {
            foreach MeetingParticipant host in meeting?.hosts ?: [] {
                if host.username == username {
                    return true;
                }
            }
        }
        
        return false;
    }

    // Helper function to check user permissions for meeting
    function checkUserPermissionForMeeting(string username, map<json> meetingData) returns boolean {
        // Check if user is the creator
        if meetingData.hasKey("createdBy") && meetingData["createdBy"].toString() == username {
            return true;
        }
        
        // Check if user is a participant
        if meetingData.hasKey("participants") {
            json[] participantsJson = <json[]>meetingData["participants"];
            foreach json participantJson in participantsJson {
                map<json> participant = <map<json>>participantJson;
                if participant.hasKey("username") && participant["username"].toString() == username {
                    return true;
                }
            }
        }
        
        // Check if user is a host
        if meetingData.hasKey("hosts") {
            json[] hostsJson = <json[]>meetingData["hosts"];
            foreach json hostJson in hostsJson {
                map<json> host = <map<json>>hostJson;
                if host.hasKey("username") && host["username"].toString() == username {
                    return true;
                }
            }
        }
        
        return false;
    }

    resource function post transcripts/[string meetingId]/generateai(http:Request req) returns AIReport|http:Response|error {
        // Authentication
        string? username = check validateAndGetUsernameFromCookie(req);
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
        
        boolean hasPermission = self.checkUserPermissionForMeeting(username, meetingData);
        if !hasPermission {
            http:Response response = new;
            response.statusCode = 403;
            response.setJsonPayload({
                message: "Unauthorized: You don't have permission to generate AI report for this meeting"
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
                message: "Transcript not found for this meeting. Please create a transcript first."
            });
            return response;
        }
        
        json transcriptJson = transcriptRecord.toJson();
        Transcript transcript = check transcriptJson.cloneWithType(Transcript);
        
        // Check if AI report already exists
        map<json> reportFilter = {
            "meetingId": meetingId
        };
        
        record {}|() existingReport = check mongodb:aiReportCollection->findOne(reportFilter);
        
        // Generate AI report content
        string reportContent = check self.generateAIReport(transcript, meetingData);
        
        string currentTime = time:utcToString(time:utcNow());
        
        if existingReport is record {} {
            // Update existing report
            json existingJson = existingReport.toJson();
            AIReport existing = check existingJson.cloneWithType(AIReport);
            
            mongodb:Update updateDoc = {
                "set": {
                    "reportContent": reportContent,
                    "generatedBy": username,
                    "updatedAt": currentTime
                }
            };
            
            _ = check mongodb:aiReportCollection->updateOne(reportFilter, updateDoc);
            
            existing.reportContent = reportContent;
            existing.generatedBy = username;
            existing.updatedAt = currentTime;
            return existing;
        } else {
            // Create new report
            AIReport newReport = {
                id: uuid:createType1AsString(),
                meetingId: meetingId,
                reportContent: reportContent,
                generatedBy: username,
                createdAt: currentTime,
                updatedAt: currentTime
            };
            
            _ = check mongodb:aiReportCollection->insertOne(newReport);
            return newReport;
        }
    }

    // Get AI report for a meeting
    resource function get reports/[string meetingId](http:Request req) returns AIReport|http:Response|error {
        // Authentication
        string? username = check validateAndGetUsernameFromCookie(req);
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
        
        json meetingJson = meeting.toJson();
        map<json> meetingData = <map<json>>meetingJson;
        
        boolean hasPermission = self.checkUserPermissionForMeeting(username, meetingData);
        if !hasPermission {
            http:Response response = new;
            response.statusCode = 403;
            response.setJsonPayload({
                message: "Unauthorized: You don't have permission to view this meeting's AI report"
            });
            return response;
        }
        
        // Get the AI report
        map<json> reportFilter = {
            "meetingId": meetingId
        };
        
        record {}|() reportRecord = check mongodb:aiReportCollection->findOne(reportFilter);
        if reportRecord is () {
            http:Response response = new;
            response.statusCode = 404;
            response.setJsonPayload({
                message: "AI report not found for this meeting. Please generate a report first."
            });
            return response;
        }
        
        json reportJson = reportRecord.toJson();
        AIReport report = check reportJson.cloneWithType(AIReport);
        
        return report;
    }

    // Get all AI reports for user's meetings
    resource function get reports(http:Request req) returns AIReport[]|http:Response|error {
        // Authentication
        string? username = check validateAndGetUsernameFromCookie(req);
        if username is () {
            http:Response response = new;
            response.statusCode = 401;
            response.setJsonPayload({
                message: "Unauthorized: Invalid or missing authentication token"
            });
            return response;
        }
        
        // Get all meetings where user has access
        map<json> meetingFilter = {
            "$or": [
                {"createdBy": username},
                {"participants.username": username},
                {"hosts.username": username}
            ]
        };
        
        stream<record {}, error?> meetingsCursor = check mongodb:meetingCollection->find(meetingFilter);
        string[] meetingIds = [];
        
        check from record {} meetingData in meetingsCursor
            do {
                json meetingJson = meetingData.toJson();
                map<json> meetingMap = <map<json>>meetingJson;
                if meetingMap.hasKey("id") {
                    meetingIds.push(meetingMap["id"].toString());
                }
            };
        
        if meetingIds.length() == 0 {
            return [];
        }
        
        // Get AI reports for these meetings
        map<json> reportFilter = {
            "meetingId": {
                "$in": meetingIds
            }
        };
        
        stream<record {}, error?> reportsCursor = check mongodb:aiReportCollection->find(reportFilter);
        AIReport[] reports = [];
        
        check from record {} reportData in reportsCursor
            do {
                json reportJson = reportData.toJson();
                AIReport report = check reportJson.cloneWithType(AIReport);
                reports.push(report);
            };
        
        return reports;
    }


    // Helper function to generate AI report using Hugging Face
    function generateAIReport(Transcript transcript, map<json> meetingData) returns string|error {
        // Build the prompt from transcript answers
        string promptBuilder = "Meeting Analysis:\n\n";
        promptBuilder += "Title: " + (meetingData.hasKey("title") ? meetingData["title"].toString() : "N/A") + "\n";
        promptBuilder += "Type: " + (meetingData.hasKey("meetingType") ? meetingData["meetingType"].toString() : "N/A") + "\n";
        promptBuilder += "Location: " + (meetingData.hasKey("location") ? meetingData["location"].toString() : "N/A") + "\n\n";
        
        promptBuilder += "Responses:\n";
        
        foreach QuestionAnswer qa in transcript.questionAnswers {
            promptBuilder += "Q: " + qa.question + "\n";
            promptBuilder += "A: " + qa.answer + "\n\n";
        }
        
        promptBuilder += "Analyze this meeting and provide: assessment, achievements, improvements needed, and recommendations in 150-200 words.";
        
        // Try multiple approaches for better success rate
        string|error result = self.tryHuggingFaceAPI(promptBuilder);
        
        if result is error {
            log:printWarn("Hugging Face API failed, using fallback: " + result.message());
            return self.generateFallbackReport(transcript, meetingData);
        }
        
        return result;
    }

    // Primary Hugging Face API call with multiple model fallbacks
    function tryHuggingFaceAPI(string prompt) returns string|error {

        
        // Try multiple free models for better success rate
        string[] models = [
            "microsoft/DialoGPT-medium",
            "facebook/blenderbot-400M-distill",
            "google/flan-t5-base",
            "microsoft/DialoGPT-small"
        ];
        
        foreach string model in models {
            string|error result = self.callHuggingFaceModel(model, prompt, hfApiKey);
            if result is string {
                return result;
            }
            log:printInfo("Model " + model + " failed, trying next...");
        }
        
        return error("All Hugging Face models failed");
    }

    // Call specific Hugging Face model
    function callHuggingFaceModel(string modelName, string prompt, string apiKey) returns string|error {
        // Create HTTP client for Hugging Face
        http:Client hfClient = check new("https://api-inference.huggingface.co", {
            timeout: 30
        });
        
        // Prepare request payload
        HuggingFaceRequest hfRequest = {
            inputs: prompt,
            parameters: {
                max_length: 300,
                temperature: 0.7,
                do_sample: true,
                top_p: 0.9
            }
        };
        
        // Prepare headers
        map<string|string[]> headers = {
            "Authorization": "Bearer " + apiKey,
            "Content-Type": "application/json"
        };
        
        string endpoint = "/models/" + modelName;
        
        // Make API call
        http:Response|error response = hfClient->post(endpoint, hfRequest, headers);
        
        if response is error {
            return error("HTTP call failed: " + response.message());
        }
        
        if response.statusCode == 503 {
            return error("Model loading, try again in 30 seconds");
        }
        
        if response.statusCode == 429 {
            return error("Rate limit exceeded");
        }
        
        if response.statusCode != 200 {
            return error("API returned status: " + response.statusCode.toString());
        }
        
        // Parse response
        json|http:ClientError responsePayload = response.getJsonPayload();
        if responsePayload is http:ClientError {
            return error("Failed to parse response");
        }
        
        // Handle different response formats
        if responsePayload is json[] {
            if responsePayload.length() > 0 {
                json firstResult = responsePayload[0];
                if firstResult is map<json> {
                    map<json> resultMap = <map<json>>firstResult;
                    if resultMap.hasKey("generated_text") {
                        return resultMap["generated_text"].toString();
                    }
                    if resultMap.hasKey("text") {
                        return resultMap["text"].toString();
                    }
                }
            }
        }
        
        return error("Unexpected response format");
    }

    // Fallback report generator
    function generateFallbackReport(Transcript transcript, map<json> meetingData) returns string {
        string report = "Meeting Analysis Report\n\n";
        report += "Meeting: " + (meetingData.hasKey("title") ? meetingData["title"].toString() : "Untitled") + "\n";
        report += "Type: " + (meetingData.hasKey("meetingType") ? meetingData["meetingType"].toString() : "N/A") + "\n\n";
        
        // Extract key information from answers
        string purpose = "";
        string agenda = "";
        string decisions = "";
        string issues = "";
        string timeManagement = "";
        string participantCount = "";
        
        foreach QuestionAnswer qa in transcript.questionAnswers {
            string question = qa.question.toLowerAscii();
            
            if question.includes("purpose") {
                purpose = qa.answer;
            } else if question.includes("agenda") {
                agenda = qa.answer;
            } else if question.includes("decisions") {
                decisions = qa.answer;
            } else if question.includes("unresolved") {
                issues = qa.answer;
            } else if question.includes("time") && question.includes("scheduled") {
                timeManagement = qa.answer;
            } else if question.includes("participants") && question.includes("contributed") {
                participantCount = qa.answer;
            }
        }
        
        // Generate structured report
        report += "Assessment:\n";
        if purpose != "" {
            report += "The meeting focused on: " + purpose + ". ";
        }
        if participantCount != "" {
            report += "Participation level: " + participantCount + ". ";
        }
        
        report += "\n\nKey Outcomes:\n";
        if decisions != "" {
            report += "Decisions made: " + decisions + ". ";
        }
        if agenda != "" {
            report += "Agenda coverage: " + agenda + ". ";
        }
        
        report += "\n\nAreas for Improvement:\n";
        if timeManagement.toLowerAscii().includes("no") || timeManagement.includes("exceed") {
            report += "Time management needs attention. ";
        }
        if issues != "" && !issues.toLowerAscii().includes("none") && !issues.toLowerAscii().includes("n/a") {
            report += "Outstanding issues: " + issues + ". ";
        }
        
        report += "\n\nRecommendations:\n";
        report += "• Continue structured agenda approach\n";
        report += "• Ensure all participants contribute actively\n";
        report += "• Follow up on unresolved items\n";
        if timeManagement.toLowerAscii().includes("no") {
            report += "• Improve time management for future meetings\n";
        }
        
        report += "\nNote: This analysis was generated from meeting transcript responses.";
        
        return report;
    }

}