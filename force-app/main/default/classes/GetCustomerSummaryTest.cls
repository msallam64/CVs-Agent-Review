@isTest
private class GetCustomerSummaryTest {
  @TestSetup
  static void setup() {
    Account acc = new Account(Name = 'Acme Corp');
    insert acc;
    insert new Contact(
      FirstName = 'Jane',
      LastName = 'Doe',
      Email = 'jane@acme.com',
      AccountId = acc.Id
    );
  }

  @isTest
  static void returnsSummaryForValidContact() {
    Contact c = [SELECT Id FROM Contact LIMIT 1];
    GetCustomerSummary.Request req = new GetCustomerSummary.Request();
    req.contactId = c.Id;
    Test.startTest();
    List<GetCustomerSummary.Response> r = GetCustomerSummary.getSummary(
      new List<GetCustomerSummary.Request>{ req }
    );
    Test.stopTest();
    System.assertEquals(1, r.size());
    System.assertEquals('Jane Doe', r[0].contactName);
    System.assertEquals('Acme Corp', r[0].accountName);
    System.assert(r[0].summary.contains('Jane Doe'));
  }

  @isTest
  static void handlesMissingContactGracefully() {
    GetCustomerSummary.Request req = new GetCustomerSummary.Request();
    req.contactId = '003000000000000AAA'; // valid shape, no record
    Test.startTest();
    List<GetCustomerSummary.Response> r = GetCustomerSummary.getSummary(
      new List<GetCustomerSummary.Request>{ req }
    );
    Test.stopTest();
    System.assert(r[0].summary.contains('No contact found'));
  }

  @isTest
  static void handlesNullIdGracefully() {
    GetCustomerSummary.Request req = new GetCustomerSummary.Request();
    req.contactId = null;
    Test.startTest();
    List<GetCustomerSummary.Response> r = GetCustomerSummary.getSummary(
      new List<GetCustomerSummary.Request>{ req }
    );
    Test.stopTest();
    System.assert(r[0].summary.contains('No Contact Id'));
  }
}