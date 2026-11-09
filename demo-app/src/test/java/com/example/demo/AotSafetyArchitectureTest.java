package com.example.demo;

import com.tngtech.archunit.core.importer.ImportOption;
import com.tngtech.archunit.junit.AnalyzeClasses;
import com.tngtech.archunit.junit.ArchTest;
import com.tngtech.archunit.lang.ArchRule;

import org.springframework.boot.autoconfigure.condition.ConditionalOnExpression;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Profile;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;
import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noMethods;

/**
 * Spring AOT evaluates these annotations once, at build time, and every environment inherits the
 * result. Here they'd silently ignore the runtime profile or property. Choose the implementation
 * inside a @Bean method instead (see AuditConfig).
 */
@AnalyzeClasses(packages = "com.example.demo", importOptions = ImportOption.DoNotIncludeTests.class)
class AotSafetyArchitectureTest {

    private static final String WHY = "Spring AOT fixes this at build time; choose the implementation inside a @Bean method instead";

    @ArchTest
    static final ArchRule noProfileOnClasses = noClasses().should()
        .beAnnotatedWith(Profile.class)
        .orShould()
        .beAnnotatedWith(ConditionalOnProperty.class)
        .orShould()
        .beAnnotatedWith(ConditionalOnExpression.class)
        .because(WHY);

    @ArchTest
    static final ArchRule noProfileOnBeanMethods = noMethods().should()
        .beAnnotatedWith(Profile.class)
        .orShould()
        .beAnnotatedWith(ConditionalOnProperty.class)
        .orShould()
        .beAnnotatedWith(ConditionalOnExpression.class)
        .because(WHY);
}
