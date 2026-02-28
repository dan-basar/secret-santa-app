-- Run this script once in your Azure SQL database to set up the schema.

CREATE TABLE Draws (
  id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
  created_at DATETIME2 DEFAULT GETUTCDATE(),
  emails_sent_at DATETIME2 NULL,
  deleted_at DATETIME2 NULL
);

CREATE TABLE Participants (
  id INT IDENTITY(1,1) PRIMARY KEY,
  draw_id UNIQUEIDENTIFIER NOT NULL REFERENCES Draws(id),
  name NVARCHAR(200) NOT NULL,
  email NVARCHAR(320) NOT NULL,
  group_name NVARCHAR(200) NULL
);

CREATE TABLE Matches (
  id INT IDENTITY(1,1) PRIMARY KEY,
  draw_id UNIQUEIDENTIFIER NOT NULL REFERENCES Draws(id),
  giver_participant_id INT NOT NULL REFERENCES Participants(id),
  receiver_participant_id INT NOT NULL REFERENCES Participants(id)
);

CREATE INDEX IX_Participants_DrawId ON Participants(draw_id);
CREATE INDEX IX_Matches_DrawId ON Matches(draw_id);

