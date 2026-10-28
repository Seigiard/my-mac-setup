
Before you accept a test as evidence, ask where its expected value comes from. Two sources make a test
green by construction, and both hide inside tests that look thorough:

- a stub, fake or stand-in that reimplements a production rule. Read the production rule it stands for
  and compare: a fake that accepts what production rejects, or orders what production leaves unordered,
  turns every test over it into a test of the fake. Name the production rule and the line of the fake
  that differs from it
- an expected value that comes from the same helper, allocator, table or code path as the value under
  test, including a historical constant copied from one earlier run of that path. The assertion then
  compares a thing with itself. Name the independent source the expected value should come from
