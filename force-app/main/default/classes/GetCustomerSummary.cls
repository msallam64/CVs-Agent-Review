/**
 * @description Agentforce-invocable action that returns a short, human-readable
 *              summary of a Contact (name, email, account, last activity date)
 *              for a given Contact Id. Backs the "Get Customer Summary" agent action.
 * @author      Mohamed Ali
 * @date        2026-06-27
 */
public with sharing class GetCustomerSummary {
  public class Request {
    // input DTO
    @InvocableVariable(
      required=true
      label='Contact Id'
      description='The Salesforce Id of the Contact to summarize, provided by the user or resolved from conversation context.'
    )
    public Id contactId;
  }

  public class Response {
    // output DTO
    @InvocableVariable(
      label='Summary'
      description='A short, readable summary of the contact combining name, email, account, and last activity. This is the agent should speak back to the user.'
    )
    public String summary;
    @InvocableVariable(
      label='Contact Name'
      description='The full name of the contact (FirstName LastName).'
    )
    public String contactName;
    @InvocableVariable(
      label='Email'
      description='The email address of the contact, or blank if none.'
    )
    public String email;
    @InvocableVariable(
      label='Account Name'
      description='The name of the account the contact belongs to, or No related account if none.'
    )
    public String accountName;
    @InvocableVariable(
      label='Last Activity Date'
      description='The date of the most recent activity for the contact as text (yyyy-mm-dd), or none on record.'
    )
    public String lastActivityDate;
  }

  /**
   * @description Returns a customer summary for each provided Contact Id. Bulk-safe:
   *              queries all requested Contacts in a single SOQL call.
   * @param requests List of Request wrappers, each holding a Contact Id.
   * @return List of Response wrappers in the same order as the input.
   */
  @InvocableMethod(
    label='Get Customer Summary'
    description='Use when a user asks for an overview, profile, details, or summary of a specific contact or customer. Takes a Contact Id and returns name, email, account, and last activity date as both a spoken summary and structured fields.'
  )
  public static List<Response> getSummary(List<Request> requests) {
    List<Response> responses = new List<Response>();

    Set<Id> contactIds = new Set<Id>(); // bulkify: collect Ids
    for (Request req : requests) {
      if (req.contactId != null)
        contactIds.add(req.contactId);
    }

    Map<Id, Contact> contactsById = new Map<Id, Contact>(
      [
        SELECT Id, Name, Email, Account.Name, LastActivityDate
        FROM Contact
        WHERE Id IN :contactIds
      ]
    );

    for (Request req : requests) {
      Response res = new Response();
      if (req.contactId == null) {
        res.summary = 'No Contact Id was provided.';
        responses.add(res);
        continue;
      }
      Contact c = contactsById.get(req.contactId);
      if (c == null) {
        res.summary = 'No contact found for the provided Id.';
        responses.add(res);
        continue;
      }
      res.contactName = c.Name;
      res.email = c.Email;
      res.accountName = (c.Account != null)
        ? c.Account.Name
        : 'No related account';
      res.lastActivityDate = (c.LastActivityDate != null)
        ? String.valueOf(c.LastActivityDate)
        : 'none on record';
      res.summary =
        'Contact: ' +
        c.Name +
        ' | Email: ' +
        (String.isBlank(c.Email) ? 'none' : c.Email) +
        ' | Account: ' +
        res.accountName +
        ' | Last activity: ' +
        (c.LastActivityDate != null
          ? String.valueOf(c.LastActivityDate)
          : 'none on record');
      responses.add(res);
    }
    return responses;
  }
}