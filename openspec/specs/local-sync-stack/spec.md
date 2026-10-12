# local-sync-stack Specification

## Purpose
Lets a developer or presenter run the backend that iPads sync with, Couchbase Server and Sync Gateway already set up for
the app, on a laptop with one command.

## Requirements

### Requirement: One-command start
The repository SHALL contain a Docker Compose stack that, from an empty state and with one command, starts Couchbase
Server and Sync Gateway and leaves Sync Gateway ready to accept the app's replication. Running the command again MUST
NOT fail or duplicate anything.

#### Scenario: First start
- **WHEN** a developer runs the start command on a machine with Docker and no previous stack data
- **THEN** after the stack reports ready, the Sync Gateway database answers on the public port and the simulator can sync with it

#### Scenario: Restart
- **WHEN** the developer stops the stack and runs the start command again
- **THEN** the stack starts with the data it had, and no step fails because something already exists

### Requirement: Data layout matches the app
The stack SHALL create a bucket holding a scope with the same name as the app's scope and one collection for each
replicated collection of the app (documents, chunks, images). The Sync Gateway database MUST serve exactly those
collections.

#### Scenario: Synced records on the server
- **WHEN** an iPad syncs a manual to the stack
- **THEN** its record, chunks and images can be found in the matching collections in the Couchbase Server web console

### Requirement: Access control
The stack SHALL create a fixed set of users, one per iPad, all with access to the shared library and permission to
write it. Requests without valid credentials MUST be refused. The Sync Gateway admin interface MUST be reachable only
from the machine running the stack.

#### Scenario: Seeded user
- **WHEN** the app connects with one of the seeded user names and its password
- **THEN** it receives the shared library and can send new documents

#### Scenario: Wrong credentials
- **WHEN** the app connects with an unknown user or a wrong password
- **THEN** Sync Gateway refuses the connection

#### Scenario: Admin port from another device
- **WHEN** an iPad on the same network tries to reach the Sync Gateway admin port of the laptop
- **THEN** the connection is refused

### Requirement: Connecting from the simulator and from an iPad
The stack's documentation SHALL give the address to enter on the Sync page for the simulator on the same machine and
for an iPad on the same network, and the seeded user names and passwords. The app MUST be able to connect to such a
local address over an unencrypted connection.

#### Scenario: iPad on the same Wi-Fi
- **WHEN** the user of a real iPad enters the laptop's network address as documented and allows local network access
- **THEN** the iPad syncs with the stack

### Requirement: Reset
The stack SHALL offer a documented way to remove all of its data and start again from empty.

#### Scenario: Wipe
- **WHEN** the developer runs the documented reset and starts the stack again
- **THEN** the server holds no documents and the seeded users exist again
