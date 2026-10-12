# Spec Delta

## MODIFIED Requirements

### Requirement: Citation navigation
Tapping a citation SHALL open the source viewer on the cited document at the cited page or section, with the cited passage highlighted. Tapping a citation of an image, or an image match, MUST show that image: an imported photo opens in an image view, and a photo inside a document opens the document at the image's page or section. For a deleted document, the app MUST show the stored passage text and indicate that the document was deleted.

#### Scenario: Open PDF citation
- **WHEN** the user taps a citation to page 42 of a PDF
- **THEN** the source viewer shows page 42 with the passage highlighted

#### Scenario: Open DOCX citation
- **WHEN** the user taps a citation to a DOCX document
- **THEN** the source viewer shows the document's text scrolled to the cited passage, highlighted

#### Scenario: Open imported photo
- **WHEN** the user taps a citation of an imported photo
- **THEN** the source viewer shows the photo, zoomable, with its title

#### Scenario: Open photo inside a manual
- **WHEN** the user taps an image match from page 14 of a PDF
- **THEN** the source viewer shows page 14

## ADDED Requirements

### Requirement: Photo questions
The chat SHALL let the user attach one photo to a question, either taken with the camera or picked from the photo library, with or without typed text. The photo MUST be analyzed on the device and MUST NOT be sent to the language model. Text recognized in the photo SHALL be used as query text, alongside any typed question. The attached photo MUST be stored with the question and shown in the chat. When the photo has no typed question, the app SHALL reply with the matching images and their passages, without invoking the language model; when nothing matches, it SHALL give the not-found response.

#### Scenario: Nameplate with a question
- **WHEN** the user photographs a nameplate reading "MODEL X200-B" and asks "how do I descale it?"
- **THEN** the answer is about descaling the X200 and cites passages from the X200 manual

#### Scenario: Photo only
- **WHEN** the user sends a photo of a unit without typing anything and a manual contains a similar photo
- **THEN** the reply lists that photo with its document and page, and the passages from that page, and no answer is generated

#### Scenario: Photo with no match
- **WHEN** the user sends a photo that matches no library image and contains no recognizable text
- **THEN** the app replies with the not-found response

#### Scenario: Camera unavailable
- **WHEN** camera access has been denied
- **THEN** the user can still pick a photo from the library, and the app explains how to allow camera access

### Requirement: Images in answers
An answer SHALL show, beside its sources, a thumbnail for each image stored on a cited page or section and for each cited image passage. Image matches shown in a reply MUST keep showing their document title and page after the document is deleted, marked as deleted, without the thumbnail.

#### Scenario: Cited page with a photo
- **WHEN** an answer cites page 14 of a manual and page 14 holds a photo
- **THEN** the answer's sources show that photo's thumbnail

#### Scenario: Deleted document
- **WHEN** a reply listed an image match from a document that has since been deleted
- **THEN** the match shows the document title and page, marked as deleted
