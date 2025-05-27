import ballerina/io;
import ballerina/http;

listener http:Listener ln = new (8080);
public function main() {
    io:println("hello");
}
