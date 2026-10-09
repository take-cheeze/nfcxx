// EXPECT: 12
// Driver for tinyxml2 (tests/realworld/run.sh builds it against the pinned upstream source).
#include "tinyxml2.h"
int main(){
  tinyxml2::XMLDocument doc;
  if (doc.Parse("<a x='1'><b>hi</b><b>yo</b></a>") != tinyxml2::XML_SUCCESS) return 1;
  auto* a = doc.FirstChildElement("a");
  if (!a) return 2;
  int x = 0; a->QueryIntAttribute("x", &x);
  int n = 0; for (auto* b = a->FirstChildElement("b"); b; b = b->NextSiblingElement("b")) ++n;
  return x * 10 + n;
}
