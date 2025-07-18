// Meeting related types
public type MeetingType "direct" | "group" | "round_robin";
public type MeetingStatus "pending" | "confirmed" | "canceled";
public type NotificationType "creation" | "cancellation" | "confirmation" | "availability_request" | "availability_update";

// User and auth types
public type User record {
    string username;
    string name = "";
    string password;
    boolean isadmin = false;
    string role = ""; 
    string phone_number = "";
    string profile_pic = "";
    string googleid = "";
    string bio = "";
    string mobile_no = "";
    string time_zone = "";
    string social_media = "";
    string industry = "";
    string company = "";
    boolean is_available = true;
    boolean calendar_connected = false;
    string refresh_token = "";
    string email_refresh_token = "";
};

public type RefreshTokenRequest record {
    string refresh_token;
};

public type TokenResponse record {
    string access_token;
    string refresh_token;
};

public type SignupRequest record {
    string username;
    string name;
    string password;
};

public type LoginRequest record {
    string username;
    string password;
};

public type GoogleLoginRequest record {
    string googleid;
    string email;
    string name;
    string picture = "";
};

public type LoginResponse record {
    string username;
    string name;
    boolean isadmin;
    string role;
    boolean success;
    boolean calendar_connected;
};

public type CalendarConnectionResponse record {
    boolean connected;
    string message;
};

public type EmailConfig record {
    string host;
    string username;
    string password;
    int port = 465;
    string frontendUrl = "http://localhost:3000";
};

public type MeetingParticipant record {
    string username;
    string access = "pending";
    string email?;
    string role?;
};

public type TimeSlot record {
    string startTime;
    string endTime;
    boolean isBestTimeSlot?;
};

public type Meeting record {
    string id;
    string title;
    string location;
    MeetingType meetingType;
    MeetingStatus status = "pending";
    string description;
    string createdBy;
    string repeat = "none";
    TimeSlot? directTimeSlot?;
    string? deadline?;
    string? groupDuration?;
    string? roundRobinDuration?;
    MeetingParticipant[]? hosts?;
    MeetingParticipant[]? participants?;
    boolean deadlineNotificationSent = false;
};

public type MeetingContent record {
    string id;
    string meetingId;
    string uploaderId;
    string username;
    ContentItem[] content;
    string createdAt;
};

public type ContentItem record {
    string url;
    string type_;
    string name;
    string uploadedAt;
};

public type SaveContentRequest record {
    ContentItem[] content;
};

public type Contact record {
    string id;
    string username;
    string email;
    string phone;
    string profileimg = "";
    string createdBy;
};

public type NotificationSettings record {
    string id;
    string username;
    boolean notifications_enabled = true;
    boolean email_notifications = false;
    boolean sms_notifications = false;
    string createdAt;
    string updatedAt;
};

public type EmailTemplate record {
    string subject;
    string bodyTemplate;
};

public type Group record {
    string id;
    string name;
    string[] contactIds;
    string createdBy;
};

public type DirectMeetingRequest record {
    string title;
    string location;
    string description;
    TimeSlot directTimeSlot;
    string[] participantIds;
    string repeat = "none";
};

public type GroupMeetingRequest record {
    string title;
    string location;
    string description;
    TimeSlot[] groupTimeSlots;
    string groupDuration;
    string[] participantIds;
    string repeat = "none";
};

public type RoundRobinMeetingRequest record {
    string title;
    string location;
    string description;
    TimeSlot[] roundRobinTimeSlots;
    string roundRobinDuration;
    string[] hostIds;
    string[] participantIds;
    string repeat = "none";
};

public type Transcript record {
    string id;
    string meetingId;
    QuestionAnswer[] questionAnswers;
    string createdAt;
    string updatedAt;
};

public type QuestionAnswer record {
    string question;
    string answer;
};

public type TranscriptRequest record {
    string meetingId;
    QuestionAnswer[] questionAnswers;
};

public type ErrorResponse record {
    string message;
    int statusCode;
};

public type DayFrequency record {
    string day;
    int frequency;
};

public type AccuracyMetric record {
    string day;
    float accuracy;
};

public type EngagementMetrics record {
    float speakingTime;
    float participantEngagement;
    float chatEngagement;
};

public type Availability record {
    string id;
    string username;
    string meetingId;
    TimeSlot[] timeSlots;
};

public type MeetingAssignment record {
    string id;
    string username;
    string meetingId;
    boolean isAdmin;
};

public type MeetingAnalytics record {
    string meetingId;
    DayFrequency[] reschedulingFrequency;
    AccuracyMetric[]|string schedulingAccuracy;
    EngagementMetrics engagement;
    string createdAt;
    string updatedAt;
};

public type Notification record {
    string id;
    string title;
    string message;
    NotificationType notificationType;
    string meetingId;
    string[] toWhom;
    string createdAt;
    boolean isRead = false;
};

public type ParticipantAvailability record {
    string id;
    string username;
    string meetingId;
    TimeSlot[] timeSlots;
    string submittedAt;
};

public type AvailabilityStats record {
    float available;
    float unavailable;
    float tendency;
};

public type ParticipationStats record {
    float participationRate;
};

public type MeetingFrequency record {
    string day;
    int count;
};

public type UserAnalytics record {
    string username;
    AvailabilityStats availability;
    ParticipationStats participation;
    MeetingFrequency[] meetingFrequency;
    string generatedAt;
};

public type Note record {
    string id;
    string username;
    string meetingId;
    string noteContent;
    string createdAt;
    string updatedAt;
};

public type ExternalMeeting record {
    string title;
    string location;
    string description;
    string createdBy;
    MeetingParticipant[]? hosts = [];
    MeetingParticipant[] participants;
    string meetingType;
    string duration?;
};

public type ExternalAvailabilityRequest record {
    string userId;
    string meetingId;
    TimeSlot[] timeSlots;
};

public type AvailabilityNotificationStatus record {
    string meetingId;
    string lastNotificationDate;
    int submissionCount;
};

public type ExternalContentRequest record {
    string content;
};


public type ExternalUserMapping record {
    string id;
    string externalUserId;
    string email;
    string meetingId;
    string createdAt;
};

public type AIReport record {
    string id;
    string meetingId;
    string reportContent;
    string generatedBy;
    string createdAt;
    string updatedAt;
};

public type HuggingFaceRequest record {
    string inputs;
    HuggingFaceParameters parameters?;
    map<json> options?;
};

public type HuggingFaceParameters record {
    int max_length?;
    float temperature?;
    boolean do_sample?;
    float top_p?;
    int num_return_sequences?;
};

public type OllamaRequest record {
    string model;
    string prompt;
    boolean Stream?;
    map<json> options?;
};