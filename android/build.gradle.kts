allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// tflite_flutter 등 일부 서드파티 플러그인이 자체 build.gradle에서
// Java(1.8)와 Kotlin(툴체인 JDK 기본값, 보통 17/21)의 JVM 타겟을 다르게 잡아둬서
// "Inconsistent JVM Target Compatibility" 빌드 에러가 난다.
// AGP 9.0의 newDsl 기본값 하에서는 서브프로젝트의 android{} 확장(BaseExtension)을
// plugins.withId 콜백에서 다시 건드리면 "sourceCompatibility has been finalized" 에러가
// 나므로, extension을 통하지 않고 JavaCompile/KotlinCompile 태스크를 직접 17로 통일한다.
subprojects {
    if (name != "app") {
        afterEvaluate {
            extensions.findByType(com.android.build.gradle.BaseExtension::class.java)?.apply {
                compileOptions {
                    sourceCompatibility = JavaVersion.VERSION_17
                    targetCompatibility = JavaVersion.VERSION_17
                }
            }
        }
    }
    tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile::class.java).configureEach {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
